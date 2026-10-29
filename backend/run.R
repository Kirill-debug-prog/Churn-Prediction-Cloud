# backend/run.R - точка входа: запуск API.
#   Локально (из корня проекта):  Rscript backend/run.R
#   В Docker:                     CMD ["Rscript", "backend/run.R"]
#
# Переменные окружения:
#   PORT            порт (облачная платформа задаёт его сама; по умолчанию 8000)
#   HOST            адрес привязки (по умолчанию 0.0.0.0, как требуют облачные платформы)
#   ALLOWED_ORIGINS адреса frontend через запятую (для CORS)

args <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
file_arg <- gsub("~+~", " ", file_arg, fixed = TRUE) # Rscript кодирует пробелы в пути как "~+~"
backend_dir <- if (length(file_arg) > 0) dirname(normalizePath(file_arg[1])) else normalizePath("backend")
Sys.setenv(CHURN_BACKEND_DIR = backend_dir)

port <- suppressWarnings(as.integer(Sys.getenv("PORT", unset = "8000")))
if (is.na(port)) stop("Переменная PORT должна быть числом.")
host <- Sys.getenv("HOST", unset = "0.0.0.0")

router <- plumber::pr(file.path(backend_dir, "plumber.R"))
# docs = FALSE: встроенная страница Swagger не нужна и лишний пакет не требуется.
plumber::pr_run(router, host = host, port = port, docs = FALSE)
