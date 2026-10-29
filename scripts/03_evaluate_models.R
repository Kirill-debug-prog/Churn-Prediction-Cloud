# Этап 3: оценка моделей на ТЕСТОВОЙ выборке, выбор основной модели, сохранение артефактов.
#
# Запуск из корня проекта:   Rscript scripts/03_evaluate_models.R
# Результат (папка artifacts/):
#   model.rds      - выбранная модель (её загружает API);
#   metrics.json   - метрики обеих моделей;
#   metadata.json  - описание признаков, модели и набора данных (для формы и /metadata).

if (!file.exists("scripts/03_evaluate_models.R")) stop("Запустите скрипт из корня проекта.")
for (pkg in c("rpart", "randomForest", "pROC", "jsonlite")) {
  if (!requireNamespace(pkg, quietly = TRUE)) stop("Не установлен пакет '", pkg, "'. Выполните: Rscript scripts/00_install_packages.R")
}
source("backend/helpers.R", encoding = "UTF-8")
source("scripts/train_utils.R", encoding = "UTF-8")
suppressPackageStartupMessages({ library(rpart); library(randomForest) })

work_split <- "artifacts/work/split.rds"
if (!file.exists(work_split)) stop("Не найден ", work_split, ". Сначала выполните scripts/02_train_models.R")
split <- readRDS(work_split)
test  <- split$test
truth <- test$churn
X     <- test[, setdiff(names(test), "churn"), drop = FALSE]

model_names <- c("rpart", "random_forest")
bundles <- lapply(model_names, function(n) readRDS(file.path("artifacts/work", paste0("model_", n, ".rds"))))
names(bundles) <- model_names

# --- Метрики на тесте ------------------------------------------------------
probs <- list()
results <- list()
for (n in model_names) {
  b <- bundles[[n]]
  probs[[n]] <- predict_churn_prob(b, X)
  results[[n]] <- list(
    name = n, label = b$model_label, hyperparameters = b$params, threshold = b$threshold,
    cv = list(roc_auc = split$tuning[[n]]$best_cv_auc,
              at_threshold = split$tuning[[n]]$cv_at_threshold),
    test = compute_metrics(truth, probs[[n]], b$threshold),
    test_default_threshold = compute_metrics(truth, probs[[n]], 0.5)
  )
  m <- results[[n]]$test
  cat(sprintf("\n%s (порог %.2f)\n  Accuracy %.4f | Precision %.4f | Recall %.4f | F1 %.4f | ROC-AUC %.4f\n",
              b$model_label, b$threshold, m$accuracy, m$precision, m$recall, m$f1, m$roc_auc))
  cat(sprintf("  Матрица ошибок: TN=%d FP=%d FN=%d TP=%d\n",
              m$confusion$tn, m$confusion$fp, m$confusion$fn, m$confusion$tp))
}

# --- Выбор основной модели -------------------------------------------------
# Правило (не по одной Accuracy!): средняя оценка = mean(F1, Recall, ROC-AUC) на тесте.
# Если разница меньше 0.01, берём дерево решений как более простое и интерпретируемое.
score <- function(m) mean(c(m$f1, m$recall, m$roc_auc), na.rm = TRUE)
scores <- vapply(results, function(r) score(r$test), numeric(1))
selected <- if (abs(scores["random_forest"] - scores["rpart"]) < 0.01) "rpart" else names(which.max(scores))
selection_rule <- paste0(
  "Основная модель выбирается по средней оценке mean(F1, Recall, ROC-AUC) на тестовой выборке; ",
  "если разница между моделями меньше 0.01, выбирается более простое дерево решений. ",
  "Гиперпараметры и порог подбирались только кросс-валидацией на обучающей выборке."
)
cat(sprintf("\nСредняя оценка: rpart = %.4f, random_forest = %.4f\nВыбрана модель: %s\n",
            scores["rpart"], scores["random_forest"], results[[selected]]$label))

# --- Сохранение модели -----------------------------------------------------
main_bundle <- bundles[[selected]]
saveRDS(main_bundle, "artifacts/model.rds", compress = "xz")

# --- metrics.json ----------------------------------------------------------
n_train <- nrow(split$train); n_test <- nrow(test)
metrics <- list(
  generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  positive_class = POSITIVE_CLASS,
  data = list(
    rows_in_file = split$data_info$rows_in_file,
    duplicates_removed = split$data_info$duplicates_removed,
    rows_used = split$data_info$rows_used,
    n_train = n_train, n_test = n_test,
    churn_share_train = mean(split$train$churn == POSITIVE_CLASS),
    churn_share_test = mean(truth == POSITIVE_CLASS),
    n_features = length(split$spec),
    excluded_features = I(as.character(split$excluded_features))
  ),
  evaluation = list(
    split = "Стратифицированное разбиение 80/20, seed = 42",
    threshold_strategy = "Порог классификации подбирается по F1 на кросс-валидационных вероятностях обучающей выборки",
    selection_rule = selection_rule,
    selection_scores = as.list(scores)
  ),
  models = results,
  selected_model = selected,
  selected_model_label = results[[selected]]$label
)
jsonlite::write_json(round_list(metrics), "artifacts/metrics.json",
                     auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA)

# --- metadata.json ---------------------------------------------------------
pkg_ver <- function(p) as.character(utils::packageVersion(p))
metadata <- list(
  project = "Churn Prediction Cloud",
  created_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  dataset = c(DATASET_INFO, list(rows_used = split$data_info$rows_used)),
  model = list(
    name = main_bundle$model_name, label = main_bundle$model_label, type = main_bundle$model_type,
    positive_class = POSITIVE_CLASS, threshold = main_bundle$threshold,
    hyperparameters = main_bundle$params
  ),
  class_labels = as.list(CLASS_LABELS_RU),
  features = spec_to_public(split$spec),
  request_format = list(
    method = "POST", path = "/predict",
    body = "{\"features\": {\"<имя признака>\": <значение>, ...}}"
  ),
  versions = list(r = R.version.string, rpart = pkg_ver("rpart"),
                  randomForest = pkg_ver("randomForest"), pROC = pkg_ver("pROC"),
                  jsonlite = pkg_ver("jsonlite")),
  disclaimer = DISCLAIMER_RU
)
jsonlite::write_json(round_list(metadata), "artifacts/metadata.json",
                     auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA)

# --- ROC-кривые для отчёта (необязательно) ---------------------------------
if (requireNamespace("ggplot2", quietly = TRUE)) {
  tryCatch({
    dir.create("docs/figures", recursive = TRUE, showWarnings = FALSE)
    curves <- do.call(rbind, lapply(model_names, function(n) {
      r <- pROC::roc(truth, probs[[n]], levels = CLASS_LEVELS, direction = "<", quiet = TRUE)
      data.frame(model = results[[n]]$label, fpr = 1 - r$specificities, tpr = r$sensitivities)
    }))
    p <- ggplot2::ggplot(curves, ggplot2::aes(fpr, tpr, colour = model)) +
      ggplot2::geom_line(linewidth = 0.9) +
      ggplot2::geom_abline(linetype = "dashed", colour = "grey50") +
      ggplot2::labs(title = "ROC-кривые на тестовой выборке", x = "Доля ложных тревог (FPR)",
                    y = "Полнота (TPR)", colour = NULL) +
      ggplot2::theme_minimal() + ggplot2::theme(legend.position = "bottom")
    ggplot2::ggsave("docs/figures/roc_curves.png", p, width = 6, height = 5, dpi = 150)
  }, error = function(e) message("ROC-график не построен: ", conditionMessage(e)))
}

cat("\nСохранено: artifacts/model.rds, artifacts/metrics.json, artifacts/metadata.json\n")
cat("Дальше: Rscript scripts/04_interpret_model.R\n")
