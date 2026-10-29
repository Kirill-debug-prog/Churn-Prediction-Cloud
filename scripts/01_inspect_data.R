# Этап 2: первичный осмотр набора данных Iranian Churn.
# Скрипт ничего не обучает и не изменяет данные: он только читает файл и печатает отчёт.
#
# Запускать из КОРНЯ проекта (папка churn-prediction-cloud):
#   Rscript scripts/01_inspect_data.R
# В RStudio: File > Open Project / Session > Set Working Directory > To Project Directory,
# затем открыть файл и нажать Source.

if (!file.exists("scripts/01_inspect_data.R")) {
  stop("Запустите скрипт из корня проекта (там, где лежат папки scripts/ и data/).")
}

source("scripts/train_utils.R", encoding = "UTF-8") # DATA_FILE, ensure_dataset()

# ---------------------------------------------------------------------------
# 1. Получение файла (скачивается с UCI или берётся из data/)
# ---------------------------------------------------------------------------
ensure_dataset()

# ---------------------------------------------------------------------------
# 2. Чтение. check.names = FALSE сохраняет исходные названия столбцов как есть.
# ---------------------------------------------------------------------------
df <- read.csv(DATA_FILE, check.names = FALSE, stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM")

# Находит столбец по шаблону, игнорируя регистр и лишние пробелы в названии.
find_col <- function(data, pattern) {
  nm <- names(data)
  idx <- grep(pattern, gsub("\\s+", " ", trimws(nm)), ignore.case = TRUE)
  if (length(idx) == 0) NA_character_ else nm[idx[1]]
}

section <- function(title) cat("\n", strrep("=", 70), "\n", title, "\n", strrep("=", 70), "\n", sep = "")

# ---------------------------------------------------------------------------
# 3. Структура
# ---------------------------------------------------------------------------
section("1. Размер и названия столбцов")
cat("Строк:", nrow(df), "  Столбцов:", ncol(df), "\n")
cat("Названия столбцов (как в файле, в кавычках - видно лишние пробелы):\n")
print(names(df))

section("2. Типы столбцов")
str(df)

section("3. Описательная статистика")
print(summary(df))

# ---------------------------------------------------------------------------
# 4. Качество данных
# ---------------------------------------------------------------------------
section("4. Пропуски по столбцам")
na_counts <- colSums(is.na(df))
print(na_counts)
cat("Всего пропусков:", sum(na_counts), "\n")

section("5. Дубликаты строк")
n_dup <- sum(duplicated(df))
cat("Полных дубликатов строк:", n_dup, sprintf("(%.1f%%)", 100 * n_dup / nrow(df)), "\n")

section("6. Уникальные значения у столбцов с малым числом категорий (<= 12)")
for (nm in names(df)) {
  u <- sort(unique(df[[nm]]))
  if (length(u) <= 12) cat(sprintf("%-28s %s\n", nm, paste(u, collapse = ", ")))
}

# ---------------------------------------------------------------------------
# 5. Целевая переменная
# ---------------------------------------------------------------------------
churn_col <- find_col(df, "^churn$")
if (is.na(churn_col)) stop("Столбец Churn не найден. Проверьте названия столбцов выше.")

section("7. Целевая переменная Churn (1 = отток, 0 = нет оттока)")
tab <- table(df[[churn_col]])
print(tab)
print(round(100 * prop.table(tab), 1))
cat("(значения выше - проценты)\n")

# ---------------------------------------------------------------------------
# 6. Проверка подозрений на утечку целевого признака
# ---------------------------------------------------------------------------
status_col <- find_col(df, "^status$")
if (!is.na(status_col)) {
  section("8. Status против Churn (проверка на утечку)")
  print(table(Status = df[[status_col]], Churn = df[[churn_col]]))
}

value_col <- find_col(df, "^customer value$")
if (!is.na(value_col)) {
  section("9. Customer Value по группам Churn")
  print(tapply(df[[value_col]], df[[churn_col]], summary))
}

# Если в файле есть и "Age", и "Age Group" (на странице UCI "Age" не описан) - смотрим, как они связаны
age_col <- find_col(df, "^age$")
agegroup_col <- find_col(df, "^age group$")
if (!is.na(age_col) && !is.na(agegroup_col)) {
  section("9b. Столбец Age (не описан на странице UCI) и Age Group")
  print(tapply(df[[age_col]], df[[agegroup_col]], function(v) paste(range(v), collapse = " - ")))
  cat("(диапазон значений Age внутри каждой группы Age Group)\n")
}

# Корреляция Спирмена каждого числового признака с Churn
section("10. Корреляция (Спирмен) признаков с Churn, по убыванию модуля")
num_cols <- setdiff(names(df)[sapply(df, is.numeric)], churn_col)
cors <- sapply(num_cols, function(nm) suppressWarnings(cor(df[[nm]], df[[churn_col]], method = "spearman")))
print(round(cors[order(-abs(cors))], 3))

# ---------------------------------------------------------------------------
# 7. Сверка с документацией UCI
# ---------------------------------------------------------------------------
section("11. Сверка столбцов с описанием на странице UCI")
expected <- c(
  "Call Failure", "Complains", "Subscription Length", "Charge Amount",
  "Seconds of Use", "Frequency of use", "Frequency of SMS",
  "Distinct Called Numbers", "Age Group", "Tariff Plan",
  "Status", "Customer Value", "Churn"
)
norm <- function(x) tolower(gsub("\\s+", " ", trimws(x)))
in_file_not_doc <- setdiff(norm(names(df)), norm(expected))
in_doc_not_file <- setdiff(norm(expected), norm(names(df)))
cat("Есть в файле, но нет в моём списке из описания:", if (length(in_file_not_doc)) paste(in_file_not_doc, collapse = ", ") else "-", "\n")
cat("Есть в описании, но нет в файле:              ", if (length(in_doc_not_file)) paste(in_doc_not_file, collapse = ", ") else "-", "\n")

# ---------------------------------------------------------------------------
# 8. График распределения Churn (для пояснительной записки)
# ---------------------------------------------------------------------------
if (requireNamespace("ggplot2", quietly = TRUE)) {
  dir.create("docs/figures", recursive = TRUE, showWarnings = FALSE)
  plot_df <- data.frame(Churn = factor(df[[churn_col]],
    levels = c(0, 1),
    labels = c("Нет оттока", "Отток")
  ))
  p <- ggplot2::ggplot(plot_df, ggplot2::aes(x = Churn)) +
    ggplot2::geom_bar() +
    ggplot2::labs(title = "Распределение целевой переменной", x = NULL, y = "Число клиентов") +
    ggplot2::theme_minimal()
  ggplot2::ggsave("docs/figures/churn_distribution.png", p, width = 5, height = 4, dpi = 150)
  cat("\nГрафик сохранён: docs/figures/churn_distribution.png\n")
}

cat("\nОсмотр данных завершён.\n")
