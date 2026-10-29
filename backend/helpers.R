# backend/helpers.R
# ---------------------------------------------------------------------------
# ОБЩИЙ код для обучения (scripts/*.R) и для API (backend/plumber.R).
# Здесь живёт всё, что должно работать ОДИНАКОВО при обучении и при прогнозе:
#   - описание признаков (FEATURE_SPEC);
#   - приведение столбцов к нужным типам (prepare_features);
#   - проверка пользовательского ввода (validate_features);
#   - расчёт вероятности оттока (predict_churn_prob).
# Файл НЕ обучает модели и не требует DALEX, поэтому его можно безопасно
# подключать из облачного контейнера.
# ---------------------------------------------------------------------------

# --- Константы -------------------------------------------------------------

# Положительный класс - ОТТОК. Все метрики и вероятности считаются для него.
POSITIVE_CLASS <- "churn"
NEGATIVE_CLASS <- "no_churn"
# Порядок важен: первым идёт "отрицательный" класс (так ожидает pROC).
CLASS_LEVELS <- c(NEGATIVE_CLASS, POSITIVE_CLASS)

CLASS_LABELS_RU <- c(
  churn    = "Вероятен отток клиента",
  no_churn = "Отток клиента маловероятен"
)

DISCLAIMER_RU <- paste(
  "Учебный исследовательский проект. Прогноз экспериментальный и не гарантирует",
  "поведение реального клиента. Выданное число - оценка модели, а не доказанная",
  "вероятность ухода: калибровка вероятностей отдельно не исследовалась."
)

DATASET_INFO <- list(
  title       = "Iranian Churn",
  citation    = "Iranian Churn [Dataset]. (2020). UCI Machine Learning Repository. https://doi.org/10.24432/C5JW3Z",
  url         = "https://archive.ics.uci.edu/dataset/563/iranian+churn+dataset",
  doi         = "10.24432/C5JW3Z",
  license     = "Creative Commons Attribution 4.0 International (CC BY 4.0)",
  license_url = "https://creativecommons.org/licenses/by/4.0/"
)

# --- Описание признаков ----------------------------------------------------
# Описания взяты со страницы набора данных UCI. Все признаки, кроме Churn,
# агрегированы за первые 9 месяцев; метка Churn - состояние клиента к 12-му месяцу.
#
# Закодированные категории (жалобы, тариф, статус, возрастная группа, уровень
# начислений) намеренно описаны как КАТЕГОРИИ (factor), а не как непрерывные числа.
# Для complains / tariff_plan / status допустимые коды заданы по документации;
# если в файле встретится другой код, обучение остановится с понятной ошибкой.
# Для charge_amount и age_group допустимые коды берутся из самих данных
# (документация: 0-9 и 1-5), см. finalize_spec().

make_numeric <- function(name, label, description, integer = TRUE) {
  list(
    name = name, type = "numeric", label = label,
    description = description, integer = integer
  )
}

make_categorical <- function(name, label, description, codes = NULL, code_labels = NULL) {
  list(
    name = name, type = "categorical", label = label,
    description = description, levels = codes, level_labels = code_labels
  )
}

FEATURE_SPEC <- list(
  make_numeric(
    "call_failure", "Сбои при звонках",
    "Количество неудачных звонков (сбоев связи) за период"
  ),
  make_categorical(
    "complains", "Жалобы",
    "Подавал ли клиент жалобы",
    c("0", "1"), c("Жалоб не было", "Была жалоба")
  ),
  make_numeric(
    "subscription_length", "Срок подписки, мес.",
    "Общая длительность подписки в месяцах"
  ),
  make_categorical(
    "charge_amount", "Уровень начислений",
    "Порядковая шкала: 0 - самый низкий уровень, 9 - самый высокий"
  ),
  make_numeric(
    "seconds_of_use", "Секунд разговора",
    "Суммарная длительность звонков в секундах"
  ),
  make_numeric(
    "frequency_of_use", "Число звонков",
    "Общее количество звонков"
  ),
  make_numeric(
    "frequency_of_sms", "Число SMS",
    "Общее количество текстовых сообщений"
  ),
  make_numeric(
    "distinct_called_numbers", "Уникальных номеров",
    "Количество различных номеров, на которые звонил клиент"
  ),
  make_categorical(
    "age_group", "Возрастная группа",
    "Порядковая шкала: 1 - младшая группа, 5 - старшая группа"
  ),
  make_categorical(
    "tariff_plan", "Тарифный план",
    "Тип тарифа",
    c("1", "2"), c("Оплата по факту (pay as you go)", "Контракт")
  ),
  make_categorical(
    "status", "Статус клиента",
    "Статус клиента за период наблюдения",
    c("1", "2"), c("Активен", "Неактивен")
  ),
  make_numeric("customer_value", "Ценность клиента",
    "Рассчитанная ценность клиента (формула в документации набора не раскрыта)",
    integer = FALSE
  )
)

# --- Загрузка и подготовка данных ------------------------------------------

# "Call  Failure" -> "call_failure", "Frequency of use" -> "frequency_of_use".
# В исходном файле встречаются двойные пробелы, поэтому названия нормализуются.
normalize_names <- function(x) {
  x <- tolower(trimws(x))
  x <- gsub("[^a-z0-9]+", "_", x)
  gsub("^_+|_+$", "", x)
}

# Читает CSV, нормализует названия и проверяет, что нужные столбцы на месте.
load_raw_data <- function(path, spec = FEATURE_SPEC) {
  if (!file.exists(path)) stop("Файл данных не найден: ", path, call. = FALSE)
  df <- utils::read.csv(path,
    check.names = FALSE, stringsAsFactors = FALSE,
    fileEncoding = "UTF-8-BOM"
  )
  names(df) <- normalize_names(names(df))
  needed <- c(vapply(spec, function(s) s$name, character(1)), "churn")
  missing <- setdiff(needed, names(df))
  if (length(missing) > 0) {
    stop("В файле нет ожидаемых столбцов: ", paste(missing, collapse = ", "),
      "\nНайдены столбцы: ", paste(names(df), collapse = ", "),
      call. = FALSE
    )
  }
  df
}

# Churn: 1 = отток, 0 = нет оттока (по документации UCI) -> понятные метки класса.
make_target <- function(churn) {
  values <- sort(unique(churn))
  if (!all(values %in% c(0, 1))) {
    stop("Churn должен содержать только 0 и 1, найдено: ", paste(values, collapse = ", "), call. = FALSE)
  }
  factor(ifelse(churn == 1, POSITIVE_CLASS, NEGATIVE_CLASS), levels = CLASS_LEVELS)
}

# Дополняет описание признаков фактами из данных:
#   levels      - допустимые категории (для charge_amount и age_group берутся из данных);
#   min/max/default - статистики ОБУЧАЮЩЕЙ выборки (stats_df), нужны форме и предупреждениям.
# raw_df  - все строки (для набора допустимых категорий);
# stats_df - обучающие строки (для min/max/значений по умолчанию).
finalize_spec <- function(spec, raw_df, stats_df = raw_df) {
  lapply(spec, function(s) {
    x_all <- raw_df[[s$name]]
    x_stats <- stats_df[[s$name]]
    if (s$type == "numeric") {
      s$min <- min(x_stats)
      s$max <- max(x_stats)
      s$default <- stats::median(x_stats)
      if (isTRUE(s$integer)) s$default <- round(s$default)
    } else {
      seen <- unique(as.character(x_all))
      if (is.null(s$levels)) {
        s$levels <- as.character(sort(unique(as.numeric(x_all))))
        s$level_labels <- s$levels
      } else {
        unexpected <- setdiff(seen, s$levels)
        if (length(unexpected) > 0) {
          stop(
            sprintf(
              "Признак '%s': в данных встретились коды (%s), которых нет в документации (%s).",
              s$name, paste(unexpected, collapse = ", "), paste(s$levels, collapse = ", ")
            ),
            call. = FALSE
          )
        }
      }
      counts <- sort(table(as.character(x_stats)), decreasing = TRUE)
      s$default <- names(counts)[1]
    }
    s
  })
}

# ЕДИНАЯ функция подготовки признаков: используется и при обучении, и в API.
# Числовые столбцы -> numeric, категории -> factor с ФИКСИРОВАННЫМ набором уровней.
prepare_features <- function(df, spec) {
  out <- list()
  for (s in spec) {
    x <- df[[s$name]]
    if (is.null(x)) stop("Нет столбца: ", s$name, call. = FALSE)
    if (s$type == "numeric") {
      out[[s$name]] <- as.numeric(x)
    } else {
      out[[s$name]] <- factor(as.character(x), levels = s$levels)
    }
  }
  as.data.frame(out, stringsAsFactors = FALSE)
}

# Публичное описание признаков для /metadata и для построения формы на frontend.
spec_to_public <- function(spec) {
  lapply(spec, function(s) {
    item <- list(name = s$name, type = s$type, label = s$label, description = s$description)
    if (s$type == "numeric") {
      item$integer <- isTRUE(s$integer)
      item$min <- s$min
      item$max <- s$max
      item$default <- s$default
    } else {
      item$levels <- lapply(seq_along(s$levels), function(i) {
        list(value = s$levels[i], label = s$level_labels[i])
      })
      item$default <- s$default
    }
    item
  })
}

# --- Проверка пользовательского ввода (API) --------------------------------

# input - результат разбора JSON (jsonlite::fromJSON(..., simplifyVector = FALSE)).
# Ожидаемая структура: {"features": {"call_failure": 3, "complains": 0, ...}}
# Возвращает list(ok, errors, warnings, data). errors - список list(field, message).
validate_features <- function(input, spec) {
  errors <- list()
  warnings <- character(0)
  add_error <- function(field, message) {
    errors[[length(errors) + 1]] <<- list(field = field, message = message)
  }
  fail <- function() list(ok = FALSE, errors = errors, warnings = warnings, data = NULL)

  features <- if (is.list(input)) input[["features"]] else NULL
  if (is.null(features) || !is.list(features) || length(features) == 0 || is.null(names(features))) {
    add_error("features", "Тело запроса должно быть JSON-объектом вида {\"features\": {...}} с характеристиками клиента.")
    return(fail())
  }

  spec_names <- vapply(spec, function(s) s$name, character(1))
  for (unknown in setdiff(names(features), spec_names)) {
    add_error(unknown, "Неизвестное поле.")
  }

  values <- list()
  for (s in spec) {
    nm <- s$name
    if (!(nm %in% names(features))) {
      add_error(nm, sprintf("Отсутствует обязательное поле '%s' (%s).", nm, s$label))
      next
    }
    v <- features[[nm]]
    if (is.null(v) || is.list(v) || length(v) != 1) {
      add_error(nm, "Ожидается одно значение (не null, не массив и не объект).")
      next
    }

    if (s$type == "numeric") {
      if (!is.numeric(v) || !is.finite(v)) {
        add_error(nm, "Ожидается число.")
        next
      }
      if (v < 0) {
        add_error(nm, "Значение не может быть отрицательным.")
        next
      }
      if (isTRUE(s$integer) && v != round(v)) {
        add_error(nm, "Ожидается целое число.")
        next
      }
      if (v < s$min || v > s$max) {
        warnings <- c(warnings, sprintf(
          "'%s' (%s): значение вне диапазона обучающих данных [%s; %s], прогноз менее надёжен.",
          nm, s$label, format(s$min, trim = TRUE), format(s$max, trim = TRUE)
        ))
      }
      values[[nm]] <- as.numeric(v)
    } else {
      if (is.logical(v) || !(is.numeric(v) || is.character(v))) {
        add_error(nm, "Ожидается код категории (число или строка).")
        next
      }
      key <- if (is.numeric(v)) format(v, scientific = FALSE, trim = TRUE) else trimws(v)
      if (!(key %in% s$levels)) {
        add_error(nm, sprintf(
          "Неизвестная категория '%s'. Допустимые значения: %s.",
          key, paste(s$levels, collapse = ", ")
        ))
        next
      }
      values[[nm]] <- key
    }
  }

  if (length(errors) > 0) {
    return(fail())
  }

  raw <- as.data.frame(values, stringsAsFactors = FALSE)
  list(ok = TRUE, errors = list(), warnings = warnings, data = prepare_features(raw, spec))
}

# --- Модель ----------------------------------------------------------------

# Сохранённая модель - это список ("bundle"): модель + описание признаков + порог.
load_bundle <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf("Файл модели не найден: %s. Сначала выполните обучение: Rscript scripts/run_all.R", path),
      call. = FALSE
    )
  }
  bundle <- readRDS(path)
  needed <- c("model_type", "model", "spec", "threshold", "model_name", "model_label")
  missing <- setdiff(needed, names(bundle))
  if (length(missing) > 0) stop("В файле модели нет полей: ", paste(missing, collapse = ", "), call. = FALSE)
  bundle
}

# Вероятность ПОЛОЖИТЕЛЬНОГО класса (отток) строго по имени столбца, а не по позиции.
#  - rpart: доля класса в листе дерева;
#  - randomForest: доля деревьев, проголосовавших за класс.
predict_churn_prob <- function(bundle, newdata) {
  probs <- switch(bundle$model_type,
    rpart = stats::predict(bundle$model, newdata = newdata, type = "prob"),
    random_forest = stats::predict(bundle$model, newdata = newdata, type = "prob"),
    stop("Неизвестный тип модели: ", bundle$model_type, call. = FALSE)
  )
  if (!(POSITIVE_CLASS %in% colnames(probs))) {
    stop("В выходе модели нет столбца '", POSITIVE_CLASS, "'", call. = FALSE)
  }
  as.numeric(probs[, POSITIVE_CLASS])
}
