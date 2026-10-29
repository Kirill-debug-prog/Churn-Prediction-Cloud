# Образ REST API. Собирается из КОРНЯ проекта:
#   docker build -f backend/Dockerfile -t churn-api .
#   docker run --rm -p 8000:8000 -e ALLOWED_ORIGINS=http://localhost:8080 churn-api
#
# Перед сборкой должны существовать artifacts/model.rds, metadata.json, metrics.json,
# importance.json (создаются командой Rscript scripts/run_all.R).

# Фиксированная версия R: пакеты ставятся из замороженного снимка CRAN (воспроизводимая сборка).
FROM rocker/r-ver:4.4.2

# Системные библиотеки для пакета plumber и его зависимостей.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsodium-dev libcurl4-openssl-dev libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# В облаке нужен только минимум: DALEX, ggplot2 и pROC НЕ ставим (они нужны лишь при обучении).
RUN R -q -e 'install.packages(c("plumber", "jsonlite", "randomForest", "rpart"))' \
 && R -q -e 'stopifnot(all(c("plumber","jsonlite","randomForest","rpart") %in% rownames(installed.packages())))'

WORKDIR /app
# Сохраняем ту же структуру, что и в репозитории: /app/backend и /app/artifacts.
COPY backend/ /app/backend/
COPY artifacts/ /app/artifacts/

# Не запускаем сервер от root.
RUN useradd --create-home --shell /usr/sbin/nologin appuser && chown -R appuser /app
USER appuser

# Платформа (Render) передаст свой PORT; 8000 - значение по умолчанию для локального запуска.
ENV PORT=8000
EXPOSE 8000

CMD ["Rscript", "backend/run.R"]
