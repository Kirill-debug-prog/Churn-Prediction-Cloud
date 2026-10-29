/*
 * validation.js - чистые функции проверки формы (без обращения к DOM).
 * Работают и в браузере (window.ChurnValidation), и в Node.js (тесты: tests/frontend/validation.test.cjs).
 *
 * Описание поля (field) приходит из GET /metadata:
 *   числовое:       { name, type: "numeric", label, integer, min, max, default }
 *   категориальное: { name, type: "categorical", label, levels: [{ value, label }], default }
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.ChurnValidation = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // Допускаем только обычную десятичную запись: 12, 12.5, 12,5. Без "1e3", "0x10", "abc".
  var NUMBER_RE = /^\d+([.,]\d+)?$/;

  /**
   * Проверяет одно значение.
   * @returns {{ok: boolean, value?: (number|string), error?: string, warning?: string}}
   */
  function validateField(field, raw) {
    var text = raw === null || raw === undefined ? "" : String(raw).trim();

    if (field.type === "numeric") {
      if (text === "") return { ok: false, error: "Введите значение." };
      if (!NUMBER_RE.test(text)) {
        return { ok: false, error: "Введите неотрицательное число (например, 12 или 12.5)." };
      }
      var num = Number(text.replace(",", "."));
      if (!isFinite(num)) return { ok: false, error: "Некорректное число." };
      if (field.integer && num !== Math.round(num)) {
        return { ok: false, error: "Нужно целое число." };
      }
      var result = { ok: true, value: num };
      if (typeof field.min === "number" && typeof field.max === "number" &&
          (num < field.min || num > field.max)) {
        result.warning = "Значение вне диапазона обучающих данных [" + field.min + "; " + field.max +
          "]: прогноз будет менее надёжным.";
      }
      return result;
    }

    if (field.type === "categorical") {
      if (text === "") return { ok: false, error: "Выберите значение." };
      var allowed = (field.levels || []).some(function (l) { return String(l.value) === text; });
      if (!allowed) return { ok: false, error: "Недопустимое значение." };
      return { ok: true, value: text };
    }

    return { ok: false, error: "Неизвестный тип поля." };
  }

  /**
   * Проверяет всю форму.
   * @param {Array} fields   поля из /metadata
   * @param {Object} rawValues  { имя: введённое значение }
   * @returns {{ok: boolean, errors: Object, warnings: Object, values: Object}}
   */
  function validateAll(fields, rawValues) {
    var errors = {}, warnings = {}, values = {};
    fields.forEach(function (f) {
      var r = validateField(f, rawValues[f.name]);
      if (r.ok) {
        values[f.name] = r.value;
        if (r.warning) warnings[f.name] = r.warning;
      } else {
        errors[f.name] = r.error;
      }
    });
    return { ok: Object.keys(errors).length === 0, errors: errors, warnings: warnings, values: values };
  }

  /** Тело запроса POST /predict: { "features": { ... } } */
  function buildPayload(values) {
    return { features: values };
  }

  /** Достаёт читаемый текст из ответа API с ошибкой (поддерживает и строки, и массивы из одного элемента). */
  function errorText(payload, fallback) {
    var e = payload && payload.error;
    if (Array.isArray(e)) e = e[0];
    return typeof e === "string" && e ? e : fallback;
  }

  return { validateField: validateField, validateAll: validateAll, buildPayload: buildPayload, errorText: errorText };
});
