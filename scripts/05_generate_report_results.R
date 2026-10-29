# Подставляет ФАКТИЧЕСКИЕ результаты эксперимента (из artifacts/metrics.json) в материалы для отчёта.
#
# Запуск из корня проекта:   Rscript scripts/05_generate_report_results.R
# Результат:
#   docs/results_generated.md       - таблицы результатов;
#   docs/report_materials.md        - блок между маркерами RESULTS:START / RESULTS:END заменяется.
# Никаких чисел вручную не вписывается: всё берётся из файла метрик.

if (!file.exists("scripts/05_generate_report_results.R")) stop("Запустите скрипт из корня проекта.")
if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Нужен пакет jsonlite")
if (!file.exists("artifacts/metrics.json")) stop("Нет artifacts/metrics.json. Сначала выполните scripts/03_evaluate_models.R")

m <- jsonlite::read_json("artifacts/metrics.json", simplifyVector = FALSE)
imp <- if (file.exists("artifacts/importance.json")) jsonlite::read_json("artifacts/importance.json", simplifyVector = FALSE) else NULL

f <- function(x, d = 3) if (is.null(x) || is.na(x)) "н/д" else formatC(x, format = "f", digits = d)
pct <- function(x) if (is.null(x)) "н/д" else sprintf("%.1f%%", 100 * x)

lines <- character(0)
add <- function(...) lines <<- c(lines, paste0(...))

add("_Блок сгенерирован скриптом `scripts/05_generate_report_results.R` из `artifacts/metrics.json` (", m$generated_at, ")._")
add("")
add("### Данные")
add("")
add(
  "- Строк в файле: ", m$data$rows_in_file, "; полных дубликатов удалено: ", m$data$duplicates_removed,
  "; использовано: ", m$data$rows_used, "."
)
add(
  "- Обучающая выборка: ", m$data$n_train, " строк (доля оттока ", pct(m$data$churn_share_train),
  "); тестовая: ", m$data$n_test, " строк (доля оттока ", pct(m$data$churn_share_test), ")."
)
add(
  "- Признаков в модели: ", m$data$n_features,
  if (length(m$data$excluded_features) > 0) paste0("; исключены по проверке на утечку: ", paste(unlist(m$data$excluded_features), collapse = ", ")) else "; исключений по проверке на утечку нет."
)
add("")
add("### Сравнение моделей на тестовой выборке (положительный класс - отток)")
add("")
add("| Модель | Порог | Accuracy | Precision | Recall | F1 | ROC-AUC |")
add("|---|---|---|---|---|---|---|")
for (r in m$models) {
  tm <- r$test
  add(
    "| ", r$label, " | ", f(r$threshold, 2), " | ", f(tm$accuracy), " | ", f(tm$precision), " | ",
    f(tm$recall), " | ", f(tm$f1), " | ", f(tm$roc_auc), " |"
  )
}
add("")
add("Те же модели при стандартном пороге 0.5:")
add("")
add("| Модель | Accuracy | Precision | Recall | F1 | ROC-AUC |")
add("|---|---|---|---|---|---|")
for (r in m$models) {
  tm <- r$test_default_threshold
  add("| ", r$label, " | ", f(tm$accuracy), " | ", f(tm$precision), " | ", f(tm$recall), " | ", f(tm$f1), " | ", f(tm$roc_auc), " |")
}
add("")
add("### Матрицы ошибок (строки - факт, столбцы - прогноз)")
add("")
for (r in m$models) {
  cm <- r$test$confusion
  add("**", r$label, "**")
  add("")
  add("| | Прогноз: нет оттока | Прогноз: отток |")
  add("|---|---|---|")
  add("| Факт: нет оттока | TN = ", cm$tn, " | FP = ", cm$fp, " |")
  add("| Факт: отток | FN = ", cm$fn, " | TP = ", cm$tp, " |")
  add("")
}
add("### Кросс-валидация на обучающей выборке и гиперпараметры")
add("")
add("| Модель | CV ROC-AUC | Гиперпараметры |")
add("|---|---|---|")
for (r in m$models) {
  hp <- paste(names(r$hyperparameters), unlist(r$hyperparameters), sep = " = ", collapse = "; ")
  add("| ", r$label, " | ", f(r$cv$roc_auc), " | ", hp, " |")
}
add("")
add("### Выбор основной модели")
add("")
add("Выбрана: **", m$selected_model_label, "**.")
add("")
add(m$evaluation$selection_rule)
add("")
add(
  "Средние оценки mean(F1, Recall, ROC-AUC): ",
  paste(sprintf("%s = %s", names(m$evaluation$selection_scores), vapply(m$evaluation$selection_scores, f, character(1), d = 4)), collapse = "; "), "."
)
if (!is.null(imp)) {
  add("")
  add("### Важность признаков")
  add("")
  add("Метод: ", imp$method)
  add("")
  add("| № | Признак | Важность |")
  add("|---|---|---|")
  for (it in imp$items) add("| ", it$rank, " | ", it$label, " (`", it$feature, "`) | ", f(it$importance, 4), " |")
}

block <- paste(lines, collapse = "\n")
dir.create("docs", showWarnings = FALSE)
writeLines(block, "docs/results_generated.md", useBytes = TRUE)
cat("Записано: docs/results_generated.md\n")

target <- "docs/report_materials.md"
if (file.exists(target)) {
  txt <- paste(readLines(target, encoding = "UTF-8", warn = FALSE), collapse = "\n")
  start <- "<!-- RESULTS:START -->"
  end <- "<!-- RESULTS:END -->"
  s <- regexpr(start, txt, fixed = TRUE)
  e <- regexpr(end, txt, fixed = TRUE)
  if (s > 0 && e > s) {
    new_txt <- paste0(substr(txt, 1, s + nchar(start) - 1), "\n", block, "\n", substr(txt, e, nchar(txt)))
    writeLines(new_txt, target, useBytes = TRUE)
    cat("Обновлён блок результатов в", target, "\n")
  } else {
    cat("В", target, "не найдены маркеры RESULTS:START / RESULTS:END - вставьте таблицы из docs/results_generated.md вручную.\n")
  }
}
