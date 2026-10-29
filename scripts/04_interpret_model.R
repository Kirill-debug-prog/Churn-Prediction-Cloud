# Этап 4: глобальная интерпретация модели (важность признаков) с помощью DALEX.
#
# Запуск из корня проекта:   Rscript scripts/04_interpret_model.R
# Результат: artifacts/importance.json (его отдаёт API) и docs/figures/feature_importance.png.
#
# Метод - пермутационная важность (permutation importance): значения одного признака
# случайно перемешиваются, и мы смотрим, насколько падает качество модели
# (потеря = 1 - AUC). Чем сильнее падает, тем больше модель опирается на признак.
#
# ВАЖНО: это важность для МОДЕЛИ, а не доказанная причина ухода клиента.
# Если признак важен для модели, это не значит, что он ВЫЗЫВАЕТ отток
# (причинно-следственную связь такой анализ не устанавливает).

if (!file.exists("scripts/04_interpret_model.R")) stop("Запустите скрипт из корня проекта.")
for (pkg in c("rpart", "randomForest", "pROC", "jsonlite")) {
  if (!requireNamespace(pkg, quietly = TRUE)) stop("Не установлен пакет '", pkg, "'. Выполните: Rscript scripts/00_install_packages.R")
}
source("backend/helpers.R", encoding = "UTF-8")
source("scripts/train_utils.R", encoding = "UTF-8")
suppressPackageStartupMessages({
  library(rpart)
  library(randomForest)
})

if (!file.exists("artifacts/model.rds")) stop("Не найден artifacts/model.rds. Сначала выполните scripts/03_evaluate_models.R")
bundle <- load_bundle("artifacts/model.rds")
split <- readRDS("artifacts/work/split.rds")
test <- split$test
X <- test[, setdiff(names(test), "churn"), drop = FALSE]
y <- as.numeric(test$churn == POSITIVE_CLASS) # 1 = отток

REPEATS <- 20 # сколько раз перемешиваем каждый признак (усредняем шум)
set.seed(SEED)

labels <- setNames(
  vapply(bundle$spec, function(s) s$label, character(1)),
  vapply(bundle$spec, function(s) s$name, character(1))
)

# --- Основной путь: DALEX ---------------------------------------------------
importance_dalex <- function() {
  if (!requireNamespace("DALEX", quietly = TRUE)) stop("Пакет DALEX не установлен")
  explainer <- DALEX::explain(
    model = bundle, data = X, y = y,
    # Явно говорим DALEX, как получить вероятность ОТТОКА (положительного класса).
    predict_function = function(m, newdata) predict_churn_prob(m, newdata),
    label = bundle$model_label, verbose = FALSE,
    model_info = list(package = "custom", ver = "1.0", type = "classification")
  )
  vi <- DALEX::model_parts(explainer,
    loss_function = DALEX::loss_one_minus_auc,
    type = "difference", B = REPEATS, N = NULL
  )
  vi <- as.data.frame(vi)
  vi <- vi[!(vi$variable %in% c("_full_model_", "_baseline_")), , drop = FALSE]
  agg <- stats::aggregate(dropout_loss ~ variable, data = vi, FUN = mean)
  list(
    method = sprintf("DALEX: пермутационная важность (потеря = 1 - AUC), %d перемешиваний, тестовая выборка", REPEATS),
    values = setNames(agg$dropout_loss, as.character(agg$variable))
  )
}

# --- Запасной путь: встроенная важность модели (если DALEX недоступен) -------
importance_fallback <- function() {
  if (bundle$model_type == "random_forest") {
    imp <- randomForest::importance(bundle$model)[, "MeanDecreaseGini"]
    method <- "Резервный метод: MeanDecreaseGini случайного леса (DALEX недоступен)"
  } else {
    imp <- bundle$model$variable.importance
    method <- "Резервный метод: variable.importance дерева rpart (DALEX недоступен)"
  }
  list(method = method, values = imp)
}

res <- tryCatch(importance_dalex(), error = function(e) {
  message("DALEX не сработал: ", conditionMessage(e), "\nИспользую резервный метод.")
  importance_fallback()
})

vals <- res$values
vals <- vals[names(labels)[names(labels) %in% names(vals)]]
vals <- sort(vals, decreasing = TRUE)
items <- lapply(seq_along(vals), function(i) {
  list(
    feature = names(vals)[i], label = unname(labels[names(vals)[i]]),
    importance = unname(vals[i]), relative = if (max(vals) > 0) max(0, unname(vals[i])) / max(vals) else 0,
    rank = i
  )
})
# Признаки, которые rpart не использовал, получают важность 0 (в variable.importance их нет).
missing_features <- setdiff(names(labels), names(vals))
for (f in missing_features) {
  items[[length(items) + 1]] <- list(
    feature = f, label = unname(labels[f]), importance = 0, relative = 0,
    rank = length(items) + 1
  )
}

out <- list(
  generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  model = bundle$model_label,
  method = res$method,
  available = TRUE,
  note = paste(
    "Важность признака для модели не доказывает причинно-следственную связь с оттоком:",
    "модель отражает закономерности в данных, а не причины поведения клиентов."
  ),
  items = items
)
jsonlite::write_json(round_list(out, 5), "artifacts/importance.json",
  auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA
)

cat("Метод:", res$method, "\n\nВажность признаков (по убыванию):\n")
for (it in items) cat(sprintf("  %2d. %-26s %.5f\n", it$rank, it$feature, it$importance))

if (requireNamespace("ggplot2", quietly = TRUE)) {
  tryCatch(
    {
      dir.create("docs/figures", recursive = TRUE, showWarnings = FALSE)
      df <- data.frame(
        label = vapply(items, function(i) i$label, character(1)),
        importance = vapply(items, function(i) i$importance, numeric(1))
      )
      df$label <- factor(df$label, levels = rev(df$label))
      p <- ggplot2::ggplot(df, ggplot2::aes(label, importance)) +
        ggplot2::geom_col() +
        ggplot2::coord_flip() +
        ggplot2::labs(
          title = "Важность признаков для модели", subtitle = res$method,
          x = NULL, y = "Падение качества при перемешивании признака"
        ) +
        ggplot2::theme_minimal()
      ggplot2::ggsave("docs/figures/feature_importance.png", p, width = 7, height = 5, dpi = 150)
    },
    error = function(e) message("График не построен: ", conditionMessage(e))
  )
}
cat("\nСохранено: artifacts/importance.json\n")
