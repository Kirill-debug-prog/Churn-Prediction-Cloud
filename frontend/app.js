/*
 * app.js — логика интерфейса Churn Prediction Cloud.
 * Работает без сторонних библиотек. Все тексты с сервера вставляются через textContent
 * (никакого innerHTML с данными API), поэтому XSS через ответ сервера исключён.
 *
 * Порядок работы:
 *   1. дождаться API (GET /health) — с учётом «засыпания» бесплатного сервера;
 *   2. загрузить /metadata, /metrics, /importance;
 *   3. построить форму из метаданных;
 *   4. по отправке: проверить ввод -> POST /predict -> показать результат.
 */
(function () {
  "use strict";

  var V = window.ChurnValidation;
  var API_URL = String((window.APP_CONFIG && window.APP_CONFIG.API_URL) || "").replace(/\/+$/, "");

  // Тайминги можно переопределить в config.js (так делают автотесты); по умолчанию - рабочие значения.
  var CFG = window.APP_CONFIG || {};
  var HEALTH_TIMEOUT_MS = CFG.HEALTH_TIMEOUT_MS || 8000;            // один запрос /health
  var HEALTH_RETRY_MS = CFG.HEALTH_RETRY_MS || 3000;                // пауза между попытками
  var HEALTH_TOTAL_LIMIT_MS = CFG.HEALTH_TOTAL_LIMIT_MS || 120000;  // сколько всего ждём пробуждения сервера
  var WAKING_HINT_AFTER_MS = CFG.WAKING_HINT_AFTER_MS || 4000;      // после этого показываем «сервер просыпается»
  var DATA_TIMEOUT_MS = CFG.DATA_TIMEOUT_MS || 20000;
  var PREDICT_TIMEOUT_MS = CFG.PREDICT_TIMEOUT_MS || 30000;

  var state = { features: [], metadata: null, ready: false, busy: false };

  // ---------- Мелкие помощники ----------

  function $(id) { return document.getElementById(id); }

  function el(tag, props, children) {
    var node = document.createElement(tag);
    Object.keys(props || {}).forEach(function (k) {
      if (k === "class") node.className = props[k];
      else if (k === "text") node.textContent = props[k];
      else node.setAttribute(k, props[k]);
    });
    (children || []).forEach(function (c) { if (c) node.appendChild(c); });
    return node;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function fmt(x, digits) { return typeof x === "number" && isFinite(x) ? x.toFixed(digits === undefined ? 3 : digits) : "—"; }
  function pct(x) { return typeof x === "number" ? (100 * x).toFixed(1) + "%" : "—"; }
  function asArray(x) { return x === undefined || x === null ? [] : [].concat(x); }

  // ---------- Запросы к API ----------

  function ApiError(kind, message, status, payload) {
    this.kind = kind;       // "network" | "timeout" | "http" | "format"
    this.message = message;
    this.status = status;
    this.payload = payload;
  }

  function fetchJson(path, options) {
    options = options || {};
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, options.timeoutMs || DATA_TIMEOUT_MS);
    var init = { method: options.method || "GET", signal: controller.signal, headers: {} };
    if (options.body !== undefined) {
      init.body = JSON.stringify(options.body);
      init.headers["Content-Type"] = "application/json";
    }
    return fetch(API_URL + path, init).then(function (res) {
      return res.text().then(function (text) {
        var payload = null;
        try { payload = text ? JSON.parse(text) : null; } catch (e) { payload = undefined; }
        if (res.ok) {
          if (payload === undefined) throw new ApiError("format", "Сервер вернул не JSON.", res.status);
          return payload;
        }
        throw new ApiError("http", "HTTP " + res.status, res.status, payload || null);
      });
    }, function (err) {
      if (err && err.name === "AbortError") throw new ApiError("timeout", "Сервер не ответил вовремя.");
      throw new ApiError("network", "Нет соединения с сервером.");
    }).then(function (v) { clearTimeout(timer); return v; }, function (e) { clearTimeout(timer); throw e; });
  }

  // ---------- Статус подключения и «пробуждение» сервера ----------

  function setStatus(kind, text, showRetry) {
    var box = $("api-status");
    box.className = "status status-" + kind;
    $("api-status-text").textContent = text;
    $("api-retry").hidden = !showRetry;
  }

  // Опрашивает /health, пока сервер не ответит. Бесплатный сервер после простоя
  // просыпается около минуты — всё это время показываем понятное сообщение.
  function waitForApi() {
    var started = Date.now();
    function attempt() {
      return fetchJson("/health", { timeoutMs: HEALTH_TIMEOUT_MS }).then(function (h) {
        if (!h || h.status !== "ok") throw new ApiError("format", "Неожиданный ответ /health.");
        return true;
      }).catch(function () {
        var elapsed = Date.now() - started;
        if (elapsed >= HEALTH_TOTAL_LIMIT_MS) return false;
        if (elapsed >= WAKING_HINT_AFTER_MS) {
          setStatus("waking", "Сервер просыпается после простоя — это может занять до минуты. Прошло " +
            Math.round(elapsed / 1000) + " с…", false);
        }
        return sleep(HEALTH_RETRY_MS).then(attempt);
      });
    }
    return attempt();
  }

  // ---------- Форма ----------

  function buildForm(features) {
    var box = $("form-fields");
    clear(box);
    features.forEach(function (f) {
      var id = "f-" + f.name;
      var control;
      if (f.type === "categorical") {
        control = el("select", { id: id, name: f.name, "aria-describedby": id + "-hint " + id + "-err" });
        (f.levels || []).forEach(function (l) {
          control.appendChild(el("option", { value: String(l.value), text: l.label === String(l.value) ? String(l.value) : l.value + " — " + l.label }));
        });
        control.value = String(f.default);
      } else {
        control = el("input", {
          id: id, name: f.name, type: "text", inputmode: "decimal", autocomplete: "off",
          value: String(f.default), "aria-describedby": id + "-hint " + id + "-err"
        });
      }
      var hint = f.description || "";
      if (f.type === "numeric" && typeof f.min === "number") {
        hint += (hint ? " " : "") + "Диапазон в обучающих данных: " + f.min + "–" + f.max + ".";
      }
      var wrapper = el("div", { class: "field", "data-name": f.name }, [
        el("label", { for: id, text: f.label }),
        control,
        el("p", { class: "hint", id: id + "-hint", text: hint }),
        el("p", { class: "field-warning", id: id + "-warn", hidden: "" }),
        el("p", { class: "field-error", id: id + "-err", role: "alert" })
      ]);
      box.appendChild(wrapper);
      control.addEventListener("input", function () { onFieldInput(f); });
      control.addEventListener("change", function () { onFieldInput(f); });
    });
    box.setAttribute("aria-busy", "false");
    $("submit-btn").disabled = false;
    $("reset-btn").disabled = false;
  }

  function readValues() {
    var values = {};
    state.features.forEach(function (f) { values[f.name] = $("f-" + f.name).value; });
    return values;
  }

  function showFieldState(name, error, warning) {
    var wrap = document.querySelector('.field[data-name="' + name + '"]');
    if (!wrap) return;
    wrap.classList.toggle("invalid", !!error);
    wrap.querySelector(".field-error").textContent = error || "";
    var w = wrap.querySelector(".field-warning");
    w.textContent = warning || "";
    w.hidden = !warning;
    var control = wrap.querySelector("input, select");
    if (error) control.setAttribute("aria-invalid", "true"); else control.removeAttribute("aria-invalid");
  }

  // Подсказка «вне диапазона» и сброс ошибки при вводе (но без придирок до отправки).
  function onFieldInput(f) {
    var r = V.validateField(f, $("f-" + f.name).value);
    showFieldState(f.name, r.ok ? "" : r.error, r.ok ? r.warning : "");
  }

  function resetForm() {
    state.features.forEach(function (f) {
      $("f-" + f.name).value = String(f.default);
      showFieldState(f.name, "", "");
    });
    $("form-error").hidden = true;
  }

  // ---------- Отправка прогноза ----------

  function setBusy(busy, label) {
    state.busy = busy;
    $("submit-btn").disabled = busy;
    $("reset-btn").disabled = busy;
    $("submit-btn").querySelector(".spinner").hidden = !busy;
    $("submit-label").textContent = label || (busy ? "Считаю…" : "Рассчитать прогноз");
  }

  function showFormError(text) {
    var box = $("form-error");
    box.textContent = text || "";
    box.hidden = !text;
  }

  function onSubmit(event) {
    event.preventDefault();
    if (state.busy) return;
    showFormError("");
    var check = V.validateAll(state.features, readValues());
    state.features.forEach(function (f) { showFieldState(f.name, check.errors[f.name], check.warnings[f.name]); });
    if (!check.ok) {
      var first = Object.keys(check.errors)[0];
      $("f-" + first).focus();
      showFormError("Исправьте отмеченные поля: пустые или некорректные значения отправить нельзя.");
      return;
    }
    setBusy(true);
    requestPrediction(check.values, true).then(function (data) {
      renderResult(data);
    }).catch(function (err) {
      showFormError(describeError(err));
      if (err && err.kind === "http" && err.status === 422) applyServerFieldErrors(err.payload);
    }).then(function () { setBusy(false); });
  }

  // Если сервер успел «заснуть» между открытием страницы и отправкой — один раз ждём его и повторяем.
  function requestPrediction(values, allowRetry) {
    return fetchJson("/predict", { method: "POST", body: V.buildPayload(values), timeoutMs: PREDICT_TIMEOUT_MS })
      .catch(function (err) {
        var connectionProblem = err instanceof ApiError && (err.kind === "network" || err.kind === "timeout" ||
          (err.kind === "http" && (err.status === 502 || err.status === 503 || err.status === 504)));
        if (!allowRetry || !connectionProblem) throw err;
        setStatus("waking", "Сервер не отвечает — возможно, он просыпается после простоя. Подключаюсь…", false);
        $("submit-label").textContent = "Жду сервер…";
        return waitForApi().then(function (ok) {
          if (!ok) {
            setStatus("error", "Не удалось подключиться к серверу.", true);
            throw err;
          }
          setStatus("ready", "Сервер готов.", false);
          $("submit-label").textContent = "Считаю…";
          return requestPrediction(values, false);
        });
      });
  }

  function describeError(err) {
    if (!(err instanceof ApiError)) return "Неожиданная ошибка: " + (err && err.message ? err.message : err);
    if (err.kind === "network") return "Нет соединения с сервером. Проверьте интернет и повторите попытку.";
    if (err.kind === "timeout") return "Сервер не ответил вовремя. Повторите попытку через минуту.";
    if (err.kind === "format") return "Сервер вернул неожиданный ответ.";
    var text = V.errorText(err.payload, "Сервер вернул ошибку (HTTP " + err.status + ").");
    return err.status >= 500 ? text + " Попробуйте позже." : text;
  }

  function applyServerFieldErrors(payload) {
    asArray(payload && payload.details).forEach(function (d) {
      var field = asArray(d.field)[0];
      if (field) showFieldState(field, asArray(d.message)[0], "");
    });
  }

  // ---------- Результат ----------

  function renderResult(data) {
    var p = data.prediction;
    var card = $("result-card");
    card.hidden = false;
    var verdict = $("result-verdict");
    verdict.textContent = p.label;
    verdict.className = "verdict " + (p.is_churn_likely ? "churn" : "no-churn");
    $("result-percent").textContent = p.churn_probability_percent.toFixed(1) + "%";
    $("result-bar").style.width = Math.max(0, Math.min(100, p.churn_probability_percent)) + "%";
    $("result-threshold").style.left = Math.max(0, Math.min(100, 100 * p.threshold)) + "%";
    $("result-threshold-text").textContent = "Вертикальная черта — порог классификации модели (" +
      (100 * p.threshold).toFixed(0) + "%): при риске не ниже порога клиент относится к вероятному оттоку.";
    $("result-model").textContent = "Модель: " + (data.model && data.model.label ? data.model.label : "—") + ".";
    var list = $("result-warnings");
    clear(list);
    asArray(data.warnings).forEach(function (w) { list.appendChild(el("li", { text: w })); });
    list.hidden = list.children.length === 0;
    $("result-disclaimer").textContent = asArray(data.disclaimer)[0] || "";
    card.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "nearest" });
  }

  // ---------- Блок «О модели» ----------

  var METRIC_COLUMNS = [
    ["accuracy", "Accuracy"], ["precision", "Precision"], ["recall", "Recall"], ["f1", "F1"], ["roc_auc", "ROC-AUC"]
  ];

  function renderModelInfo(metadata, metrics) {
    var body = $("model-body");
    clear(body);
    if (metadata && metadata.model) {
      var kv = el("dl", { class: "kv" });
      [["Основная модель", metadata.model.label],
      ["Порог классификации", pct(metadata.model.threshold)],
      ["Положительный класс", "отток клиента"]].forEach(function (row) {
        kv.appendChild(el("dt", { text: row[0] }));
        kv.appendChild(el("dd", { text: String(row[1]) }));
      });
      body.appendChild(kv);
    }
    if (!metrics || !metrics.models) {
      body.appendChild(el("p", { class: "muted", text: "Метрики качества сейчас недоступны." }));
      return;
    }

    var d = metrics.data || {};
    body.appendChild(el("p", {
      class: "muted small", text:
        "Метрики посчитаны на отложенной тестовой выборке (" + (d.n_test || "?") + " клиентов), которую модель не видела при обучении. " +
        "Доля оттока в данных — " + pct(d.churn_share_train) + ": классы несбалансированы, поэтому одной Accuracy недостаточно " +
        "(модель, всегда отвечающая «оттока не будет», получила бы высокую Accuracy, но не нашла бы ни одного ушедшего). " +
        "Важны также Recall (какую долю реального оттока модель находит), Precision, F1 и ROC-AUC."
    }));

    var head = el("tr", {}, [el("th", { text: "Модель" })].concat(
      METRIC_COLUMNS.map(function (c) { return el("th", { text: c[1] }); })));
    var tbody = el("tbody");
    Object.keys(metrics.models).forEach(function (key) {
      var m = metrics.models[key];
      var isSel = key === metrics.selected_model;
      var nameCell = el("td", { text: m.label });
      if (isSel) nameCell.appendChild(el("span", { class: "badge", text: "основная" }));
      var row = el("tr", { class: isSel ? "selected" : "" }, [nameCell].concat(
        METRIC_COLUMNS.map(function (c) { return el("td", { text: fmt(m.test && m.test[c[0]]) }); })));
      tbody.appendChild(row);
    });
    body.appendChild(el("div", { class: "table-scroll" }, [
      el("table", {}, [el("thead", {}, [head]), tbody])
    ]));

    var sel = metrics.models[metrics.selected_model];
    if (sel && sel.test && sel.test.confusion) {
      var c = sel.test.confusion;
      body.appendChild(el("h3", { class: "subhead", text: "Матрица ошибок основной модели (тестовая выборка)" }));
      body.appendChild(el("div", { class: "table-scroll" }, [el("table", { class: "cm" }, [
        el("thead", {}, [el("tr", {}, [el("th", { text: "" }), el("th", { text: "Прогноз: нет оттока" }), el("th", { text: "Прогноз: отток" })])]),
        el("tbody", {}, [
          el("tr", {}, [el("td", { text: "Факт: нет оттока" }), el("td", { text: String(c.tn) }), el("td", { text: String(c.fp) })]),
          el("tr", {}, [el("td", { text: "Факт: отток" }), el("td", { text: String(c.fn) }), el("td", { text: String(c.tp) })])
        ])
      ])]));
    }
  }

  // ---------- Блок «Важность признаков» ----------

  function renderImportance(data) {
    var body = $("importance-body");
    clear(body);
    var items = asArray(data && data.items);
    if (!data || data.available === false || items.length === 0) {
      body.appendChild(el("p", { class: "muted", text: "Анализ важности признаков недоступен." }));
      return;
    }
    body.appendChild(el("p", { class: "muted small", text: asArray(data.method)[0] || "" }));
    var list = el("ul", { class: "bars" });
    items.forEach(function (it) {
      var rel = Math.max(0, Math.min(1, Number(it.relative) || 0));
      list.appendChild(el("li", { class: "bar-row" }, [
        el("span", { text: it.label }),
        el("div", { class: "bar-track", "aria-hidden": "true" }, [
          (function () { var f = el("div", { class: "bar-fill" }); f.style.width = (rel * 100).toFixed(1) + "%"; return f; })()
        ]),
        el("span", { class: "bar-value", text: fmt(Number(it.importance), 4) })
      ]));
    });
    body.appendChild(list);
    body.appendChild(el("p", { class: "muted small", text: asArray(data.note)[0] || "" }));
  }

  // ---------- Запуск ----------

  function init() {
    state.ready = false;
    setStatus("connecting", "Подключение к серверу…", false);
    $("submit-btn").disabled = true;
    $("reset-btn").disabled = true;

    waitForApi().then(function (ok) {
      if (!ok) {
        setStatus("error", "Не удалось подключиться к серверу. Проверьте адрес API в config.js или повторите попытку.", true);
        return null;
      }
      setStatus("ready", "Сервер готов.", false);
      state.ready = true;
      return Promise.all([
        fetchJson("/metadata"),
        fetchJson("/metrics").catch(function () { return null; }),
        fetchJson("/importance").catch(function () { return null; })
      ]).then(function (res) {
        state.metadata = res[0];
        state.features = asArray(res[0].features);
        buildForm(state.features);
        renderModelInfo(res[0], res[1]);
        renderImportance(res[2]);
      }).catch(function (err) {
        setStatus("error", "Не удалось загрузить описание модели: " + describeError(err), true);
      });
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    $("predict-form").addEventListener("submit", onSubmit);
    $("reset-btn").addEventListener("click", resetForm);
    $("api-retry").addEventListener("click", init);
    init();
  });
})();
