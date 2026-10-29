# Этап 3: обучение двух моделей (дерево решений rpart и случайный лес randomForest).
#
# Запуск из КОРНЯ проекта:   Rscript scripts/02_train_models.R
#
# Что делает скрипт:
#   1. читает данные и удаляет полные дубликаты строк;
#   2. делит данные 80/20 (стратифицированно, seed = 42);
#   3. проверяет признаки на утечку целевой переменной (только по обучающей выборке);
#   4. подбирает гиперпараметры 5-кратной кросс-валидацией НА ОБУЧАЮЩЕЙ выборке;
#   5. подбирает порог классификации (по F1) на кросс-валидационных вероятностях;
#   6. обучает финальные модели на всей обучающей выборке и сохраняет их.
# Тестовая выборка здесь НЕ используется - она нужна только в 03_evaluate_models.R.

if (!file.exists("scripts/02_train_models.R")) {
  stop("Запустите скрипт из корня проекта (там, где лежат папки scripts/ и backend/).")
}
for (pkg in c("rpart", "randomForest", "pROC")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Не установлен пакет '", pkg, "'. Выполните: Rscript scripts/00_install_packages.R")
  }
}

source("backend/helpers.R", encoding = "UTF-8")
source("scripts/train_utils.R", encoding = "UTF-8")

dir.create("artifacts/work", recursive = TRUE, showWarnings = FALSE)
set.seed(SEED)

# --- 1. Данные -------------------------------------------------------------
ensure_dataset()
raw <- load_raw_data(DATA_FILE, FEATURE_SPEC)
n_raw <- nrow(raw)
raw <- raw[!duplicated(raw), , drop = FALSE]
n_duplicates <- n_raw - nrow(raw)
cat(sprintf(
  "Строк в файле: %d; удалено полных дубликатов: %d; осталось: %d\n",
  n_raw, n_duplicates, nrow(raw)
))
# Почему удаляем: одинаковые строки могли бы попасть и в обучающую, и в тестовую
# выборку - тогда модель "узнавала" бы тест, и метрики были бы завышены.

stopifnot(!anyNA(raw[, c(vapply(FEATURE_SPEC, function(s) s$name, character(1)), "churn")]))
y <- make_target(raw$churn)
cat("Распределение классов (после удаления дубликатов):\n")
print(table(y))
cat(sprintf("Доля оттока: %.1f%%\n", 100 * mean(y == POSITIVE_CLASS)))

# --- 2. Разбиение 80/20 ----------------------------------------------------
train_idx <- stratified_split(y, train_fraction = 0.8, seed = SEED)
test_idx <- setdiff(seq_len(nrow(raw)), train_idx)
cat(sprintf(
  "Обучающая выборка: %d строк (отток %.1f%%); тестовая: %d строк (отток %.1f%%)\n",
  length(train_idx), 100 * mean(y[train_idx] == POSITIVE_CLASS),
  length(test_idx), 100 * mean(y[test_idx] == POSITIVE_CLASS)
))

# --- 3. Проверка на утечку (только обучающая выборка) -----------------------
cat("\nПроверка утечки: AUC каждого признака поодиночке против Churn (обучающая выборка)\n")
leak_table <- do.call(rbind, lapply(FEATURE_SPEC, function(s) {
  data.frame(
    feature = s$name,
    univariate_auc = univariate_auc(as.numeric(raw[[s$name]][train_idx]), y[train_idx]),
    stringsAsFactors = FALSE
  )
}))
leak_table <- leak_table[order(-leak_table$univariate_auc), ]
print(leak_table, row.names = FALSE)
excluded <- leak_table$feature[leak_table$univariate_auc >= LEAKAGE_AUC_THRESHOLD]
if (length(excluded) > 0) {
  warning("Подозрение на утечку, признаки исключены из модели: ", paste(excluded, collapse = ", "))
} else {
  cat("Признаков с подозрительно высокой разделяющей способностью нет (порог ",
    LEAKAGE_AUC_THRESHOLD, ").\n",
    sep = ""
  )
}
spec <- Filter(function(s) !(s$name %in% excluded), FEATURE_SPEC)
# Допустимые категории берём по всем данным, min/max/значения по умолчанию - по обучающим.
spec <- finalize_spec(spec, raw_df = raw, stats_df = raw[train_idx, , drop = FALSE])

# --- 4. Таблицы признаков --------------------------------------------------
features_all <- prepare_features(raw, spec) # ТА ЖЕ функция, что и в API
train <- data.frame(features_all[train_idx, , drop = FALSE], churn = y[train_idx])
test <- data.frame(features_all[test_idx, , drop = FALSE], churn = y[test_idx])
rownames(train) <- NULL
rownames(test) <- NULL
stopifnot(!anyNA(train), !anyNA(test), !("churn" %in% names(features_all)))

# --- 5. Подбор гиперпараметров ---------------------------------------------
n_features <- length(spec)
folds <- stratified_folds(train$churn, k = 5, seed = SEED)

model_defs <- list(
  rpart = list(
    label = "Дерево решений (rpart)",
    grid = expand.grid(
      cp = c(0.0005, 0.001, 0.005, 0.01, 0.02),
      minsplit = c(10, 20), maxdepth = c(5, 8, 12),
      KEEP.OUT.ATTRS = FALSE
    )
  ),
  random_forest = list(
    label = "Случайный лес (randomForest)",
    # ntree = 300 - компромисс между качеством и размером модели (бесплатный сервер: 512 МБ ОЗУ).
    grid = expand.grid(
      mtry = unique(pmin(c(2, 3, 4, 6), n_features)),
      nodesize = c(1, 5, 10), ntree = 300,
      KEEP.OUT.ATTRS = FALSE
    )
  )
)

tuning <- list()
for (name in names(model_defs)) {
  def <- model_defs[[name]]
  cat(sprintf("\n=== %s: перебор %d комбинаций (5-fold CV на обучающей выборке) ===\n", def$label, nrow(def$grid)))
  tuned <- tune_model(name, train, def$grid, folds, seed = SEED)

  # Порог по F1 на вероятностях отложенных фолдов (не на тесте!).
  threshold <- best_threshold(train$churn, tuned$best_oof)
  cv_at_threshold <- compute_metrics(train$churn, tuned$best_oof, threshold)
  cat(sprintf("Лучшие параметры: %s\n", paste(names(tuned$best_params), unlist(tuned$best_params), sep = "=", collapse = ", ")))
  cat(sprintf(
    "CV ROC-AUC = %.4f; порог по F1 = %.2f (CV F1 = %.4f, CV Recall = %.4f)\n",
    tuned$best_cv_auc, threshold, cv_at_threshold$f1, cv_at_threshold$recall
  ))

  # --- 6. Финальная модель на всей обучающей выборке ---
  set.seed(SEED)
  final_fit <- fit_model(name, train, tuned$best_params)
  bundle <- list(
    model_type     = name,
    model_name     = name,
    model_label    = def$label,
    model          = final_fit,
    spec           = spec,
    threshold      = threshold,
    params         = tuned$best_params,
    positive_class = POSITIVE_CLASS,
    class_levels   = CLASS_LEVELS,
    seed           = SEED,
    trained_at     = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
  )
  saveRDS(bundle, file.path("artifacts/work", paste0("model_", name, ".rds")), compress = "xz")
  utils::write.csv(tuned$table, file.path("artifacts", paste0("tuning_", name, ".csv")), row.names = FALSE)

  tuning[[name]] <- list(
    label = def$label, best_params = tuned$best_params, best_cv_auc = tuned$best_cv_auc,
    threshold = threshold, cv_at_threshold = cv_at_threshold, n_combinations = nrow(def$grid)
  )
}

saveRDS(list(
  train = train, test = test, spec = spec, excluded_features = excluded,
  leakage_table = leak_table, tuning = tuning,
  data_info = list(rows_in_file = n_raw, duplicates_removed = n_duplicates, rows_used = nrow(raw)),
  seed = SEED
), "artifacts/work/split.rds", compress = "xz")

cat("\nГотово. Модели сохранены в artifacts/work/. Дальше: Rscript scripts/03_evaluate_models.R\n")
