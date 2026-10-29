# Данные

Проект использует открытый набор данных **Iranian Churn** из UCI Machine Learning Repository.

- Страница набора: https://archive.ics.uci.edu/dataset/563/iranian+churn+dataset
- DOI: https://doi.org/10.24432/C5JW3Z
- Лицензия: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Цитирование (формат UCI):
  *Iranian Churn [Dataset]. (2020). UCI Machine Learning Repository. https://doi.org/10.24432/C5JW3Z*
- Содержимое: 3150 строк (клиентов), данные анонимны, персональных данных нет.

## Как получить файл

Скрипт `scripts/01_inspect_data.R` пытается скачать архив сам. Если не получилось (нет сети, блокировка), скачайте вручную:

1. Откройте страницу набора и нажмите **Download** (архив `iranian+churn+dataset.zip`, ~41 КБ).
2. Распакуйте архив.
3. Положите файл **`Customer Churn.csv`** в эту папку (`data/`).

Файл в git не коммитится (см. `.gitignore`).
