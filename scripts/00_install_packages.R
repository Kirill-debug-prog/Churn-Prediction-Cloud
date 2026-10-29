# Установка всех R-пакетов проекта.
#
# Запуск из корня проекта:  Rscript scripts/00_install_packages.R
# Или в RStudio: открыть файл и нажать Source.

packages <- c(
  rpart          = "дерево решений",
  randomForest   = "случайный лес",
  pROC           = "ROC-AUC",
  jsonlite       = "JSON",
  ggplot2        = "графики для отчёта",
  DALEX          = "интерпретация модели (этап 4)",
  plumber        = "REST API (этап 5)",
  httr           = "тесты API (tests/test_api.R)"
)

missing <- names(packages)[!names(packages) %in% rownames(installed.packages())]

if (length(missing) == 0) {
  message("Все пакеты уже установлены.")
} else {
  message("Устанавливаю: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
}

# Проверка: каждый пакет должен загружаться
cat("\n")
all_ok <- TRUE
for (p in names(packages)) {
  ok <- requireNamespace(p, quietly = TRUE)
  all_ok <- all_ok && ok
  cat(sprintf(
    "%-14s %-6s версия %-10s %s\n", p, if (ok) "OK" else "ОШИБКА",
    if (ok) as.character(packageVersion(p)) else "-", packages[[p]]
  ))
}
cat("\nВерсия R:", R.version.string, "\n")
if (!all_ok) {
  cat("\nЧасть пакетов не установилась. Пришлите текст ошибки выше - разберём причину.\n")
  quit(status = 1)
}
