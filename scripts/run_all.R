# Запускает весь конвейер подряд: осмотр данных -> обучение -> оценка -> интерпретация -> отчёт.
# Запуск из корня проекта:   Rscript scripts/run_all.R
# Каждый шаг можно запускать и отдельно (см. README).

if (!file.exists("scripts/run_all.R")) stop("Запустите скрипт из корня проекта.")

steps <- c(
  "scripts/01_inspect_data.R",
  "scripts/02_train_models.R",
  "scripts/03_evaluate_models.R",
  "scripts/04_interpret_model.R",
  "scripts/05_generate_report_results.R"
)
for (s in steps) {
  cat("\n", strrep("#", 70), "\n# ", s, "\n", strrep("#", 70), "\n", sep = "")
  source(s, local = new.env(), encoding = "UTF-8")
}
cat("\nВесь конвейер выполнен. Артефакты лежат в папке artifacts/.\n")
