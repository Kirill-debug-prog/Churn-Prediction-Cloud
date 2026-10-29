# scripts/train_utils.R
# ---------------------------------------------------------------------------
# Вспомогательные функции ТОЛЬКО для обучения и оценки (в API они не нужны).
# Подключается через source("scripts/train_utils.R") после backend/helpers.R.
# ---------------------------------------------------------------------------

DATA_DIR <- "data"
DATA_FILE <- file.path(DATA_DIR, "Customer Churn.csv")
DATA_URL <- "https://archive.ics.uci.edu/static/public/563/iranian+churn+dataset.zip"

SEED <- 42
# Если один признак ПОЧТИ ИДЕАЛЬНО разделяет классы сам по себе, это подозрение на
# утечку целевой переменной. Такой признак исключается автоматически.
LEAKAGE_AUC_THRESHOLD <- 0.97

# --- Данные ----------------------------------------------------------------

# Скачивает и распаковывает набор данных, если файла ещё нет.
# Данные НЕ подменяются случайными: при неудаче скрипт останавливается с инструкцией.
ensure_dataset <- function() {
  if (file.exists(DATA_FILE)) {
    return(invisible(DATA_FILE))
  }
  message("Файл ", DATA_FILE, " не найден, пробую скачать с UCI...")
  zip_path <- tempfile(fileext = ".zip")
  ok <- tryCatch(
    {
      utils::download.file(DATA_URL, zip_path, mode = "wb", quiet = TRUE)
      TRUE
    },
    error = function(e) FALSE,
    warning = function(w) FALSE
  )
  csv <- character(0)
  if (ok) {
    unzip_dir <- tempfile("churn_unzip_")
    utils::unzip(zip_path, exdir = unzip_dir)
    csv <- list.files(unzip_dir, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  }
  if (length(csv) == 0) {
    stop(
      "Автоматическая загрузка не удалась.\n",
      "Скачайте архив вручную: ", "https://archive.ics.uci.edu/dataset/563/iranian+churn+dataset\n",
      "Распакуйте его и положите файл 'Customer Churn.csv' в папку data/ (см. data/README.md).",
      call. = FALSE
    )
  }
  dir.create(DATA_DIR, showWarnings = FALSE)
  file.copy(csv[1], DATA_FILE, overwrite = TRUE)
  message("Файл скачан: ", DATA_FILE)
  invisible(DATA_FILE)
}

# --- Разбиение -------------------------------------------------------------

# Стратифицированное разбиение: доля классов в обеих выборках примерно одинакова.
# Возвращает индексы обучающей выборки. set.seed делает результат воспроизводимым.
stratified_split <- function(y, train_fraction = 0.8, seed = SEED) {
  set.seed(seed)
  by_class <- split(seq_along(y), y)
  train_idx <- unlist(lapply(by_class, function(ix) {
    ix[sample.int(length(ix), size = round(length(ix) * train_fraction))]
  }), use.names = FALSE)
  sort(train_idx)
}

# Номера фолдов для k-кратной стратифицированной кросс-валидации.
stratified_folds <- function(y, k = 5, seed = SEED) {
  set.seed(seed)
  fold <- integer(length(y))
  for (cl in levels(y)) {
    ix <- which(y == cl)
    fold[ix] <- sample(rep_len(seq_len(k), length(ix)))
  }
  fold
}

# --- Модели ----------------------------------------------------------------

# train - data.frame с признаками и столбцом `churn` (factor).
fit_model <- function(model_type, train, params) {
  feature_cols <- setdiff(names(train), "churn")
  if (model_type == "rpart") {
    fit <- rpart::rpart(
      churn ~ .,
      data = train, method = "class",
      control = rpart::rpart.control(
        cp = params$cp, minsplit = params$minsplit,
        maxdepth = params$maxdepth, xval = 0
      )
    )
    # Формула помнит окружение функции (а в нём - обучающие данные). Обрезаем,
    # чтобы в сохранённой модели не оказалось копии данных.
    attr(fit$terms, ".Environment") <- globalenv()
    fit
  } else if (model_type == "random_forest") {
    # Интерфейс x/y (без формулы): модель не тянет за собой окружение с данными.
    fit <- randomForest::randomForest(
      x = train[, feature_cols, drop = FALSE], y = train$churn,
      ntree = params$ntree, mtry = params$mtry, nodesize = params$nodesize
    )
    fit$inbag <- NULL
    fit
  } else {
    stop("Неизвестный тип модели: ", model_type, call. = FALSE)
  }
}

# Вероятности отложенных фолдов ("out-of-fold"): каждая строка предсказана моделью,
# которая её НЕ видела. Тестовая выборка здесь не участвует.
cv_probs <- function(model_type, train, folds, params) {
  oof <- rep(NA_real_, nrow(train))
  feature_cols <- setdiff(names(train), "churn")
  for (k in sort(unique(folds))) {
    fit <- fit_model(model_type, train[folds != k, , drop = FALSE], params)
    holdout <- train[folds == k, feature_cols, drop = FALSE]
    oof[folds == k] <- predict_churn_prob(list(model_type = model_type, model = fit), holdout)
  }
  oof
}

# Перебор сетки гиперпараметров по CV ROC-AUC (порог-независимая метрика).
tune_model <- function(model_type, train, grid, folds, seed = SEED) {
  oof_list <- vector("list", nrow(grid))
  cv_auc <- numeric(nrow(grid))
  for (i in seq_len(nrow(grid))) {
    set.seed(seed)
    params <- as.list(grid[i, , drop = FALSE])
    oof_list[[i]] <- cv_probs(model_type, train, folds, params)
    cv_auc[i] <- compute_auc(train$churn, oof_list[[i]])
    message(sprintf(
      "  [%s] %d/%d  %s  CV ROC-AUC = %.4f", model_type, i, nrow(grid),
      paste(names(params), unlist(params), sep = "=", collapse = " "), cv_auc[i]
    ))
  }
  best <- which.max(cv_auc)
  list(
    table       = cbind(grid, cv_roc_auc = cv_auc),
    best_params = as.list(grid[best, , drop = FALSE]),
    best_oof    = oof_list[[best]],
    best_cv_auc = cv_auc[best]
  )
}

# --- Метрики ---------------------------------------------------------------

compute_auc <- function(truth, prob) {
  r <- pROC::roc(
    response = truth, predictor = prob, levels = CLASS_LEVELS,
    direction = "<", quiet = TRUE
  )
  as.numeric(pROC::auc(r))
}

safe_div <- function(a, b) if (b == 0) NA_real_ else a / b

# Положительный класс - ОТТОК. truth - factor с уровнями CLASS_LEVELS.
compute_metrics <- function(truth, prob, threshold) {
  pred_pos <- prob >= threshold
  is_pos <- truth == POSITIVE_CLASS
  tp <- sum(pred_pos & is_pos)
  fp <- sum(pred_pos & !is_pos)
  fn <- sum(!pred_pos & is_pos)
  tn <- sum(!pred_pos & !is_pos)
  precision <- safe_div(tp, tp + fp)
  recall <- safe_div(tp, tp + fn)
  f1 <- if (is.na(precision) || is.na(recall) || (precision + recall) == 0) {
    NA_real_
  } else {
    2 * precision * recall / (precision + recall)
  }
  list(
    threshold = threshold,
    accuracy  = safe_div(tp + tn, tp + tn + fp + fn),
    precision = precision,
    recall    = recall,
    f1        = f1,
    roc_auc   = compute_auc(truth, prob),
    confusion = list(tn = tn, fp = fp, fn = fn, tp = tp)
  )
}

# Порог, максимизирующий F1 на кросс-валидационных вероятностях ОБУЧАЮЩЕЙ выборки.
# Нужен, потому что отток - редкий класс, и порог 0.5 обычно даёт низкий Recall.
best_threshold <- function(truth, prob, grid = seq(0.05, 0.95, by = 0.01)) {
  f1s <- vapply(grid, function(t) {
    f <- compute_metrics_f1(truth, prob, t)
    if (is.na(f)) -1 else f
  }, numeric(1))
  top <- which(f1s >= max(f1s) - 1e-12)
  grid[top[which.min(abs(grid[top] - 0.5))]] # при равенстве - ближе к 0.5
}

compute_metrics_f1 <- function(truth, prob, threshold) {
  pred_pos <- prob >= threshold
  is_pos <- truth == POSITIVE_CLASS
  tp <- sum(pred_pos & is_pos)
  fp <- sum(pred_pos & !is_pos)
  fn <- sum(!pred_pos & is_pos)
  if (2 * tp + fp + fn == 0) {
    return(NA_real_)
  }
  2 * tp / (2 * tp + fp + fn)
}

# AUC одного признака против Churn (для проверки утечки). Значение всегда >= 0.5.
univariate_auc <- function(x, truth) {
  tryCatch(
    {
      r <- pROC::roc(
        response = truth, predictor = as.numeric(x), levels = CLASS_LEVELS,
        direction = "auto", quiet = TRUE
      )
      as.numeric(pROC::auc(r))
    },
    error = function(e) 0.5
  )
}

round_list <- function(x, digits = 4) {
  if (is.list(x)) {
    return(lapply(x, round_list, digits = digits))
  }
  if (is.numeric(x)) {
    return(round(x, digits))
  }
  x
}
