/* Local highlighter, copy buttons, and sidebar search. No network. */
(function () {
  var KEYWORDS = {
    elixir: "def defp defmodule defmacro defmacrop do end fn when case cond if unless else true false nil with use alias import require raise receive after quote unquote and or in not",
    erlang: "case of end if when receive after begin fun try catch throw andalso orelse band bor bxor bnot bsl bsr div rem true false",
    lfe: "defun defmacro case let let* lambda match-lambda when cond if progn begin receive after try catch tuple list binary",
    gleam: "pub fn type case let use import if else true false nil todo panic opaque",
    c: "int char void const static struct enum typedef return if else for while do switch case break continue sizeof unsigned long short include define",
    shell: "if then else fi for in do done case esac while set export echo printf",
    css: "important",
    js: "const let var function return if else for while do switch case break continue new class import export from true false null undefined async await",
    json: "true false null",
    sql: "select from where and or insert into values update set delete create table if not exists primary key with order by limit"
  };

  function words(lang) {
    var raw = KEYWORDS[lang] || "";
    var set = {};
    raw.split(/\s+/).forEach(function (w) { if (w) set[w] = true; });
    return set;
  }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function span(cls, text) {
    return '<span class="' + cls + '">' + esc(text) + "</span>";
  }

  function starts(src, i, token) {
    return src.slice(i, i + token.length) === token;
  }

  function highlight(src, lang) {
    var kw = words(lang);
    var out = "";
    var i = 0;
    var n = src.length;
    while (i < n) {
      var ch = src[i];
      var rest = src.slice(i);

      if (lang === "elixir" && ch === "#") {
        var nl = src.indexOf("\n", i);
        var end = nl === -1 ? n : nl;
        out += span("tok-cmt", src.slice(i, end));
        i = end;
        continue;
      }
      if ((lang === "erlang" || lang === "lfe") && ch === "%") {
        var nl2 = src.indexOf("\n", i);
        var end2 = nl2 === -1 ? n : nl2;
        out += span("tok-cmt", src.slice(i, end2));
        i = end2;
        continue;
      }
      if (lang === "lfe" && ch === ";") {
        var nl3 = src.indexOf("\n", i);
        var end3 = nl3 === -1 ? n : nl3;
        out += span("tok-cmt", src.slice(i, end3));
        i = end3;
        continue;
      }
      if ((lang === "js" || lang === "c" || lang === "gleam" || lang === "css") && starts(src, i, "/*")) {
        var close = src.indexOf("*/", i + 2);
        var endc = close === -1 ? n : close + 2;
        out += span("tok-cmt", src.slice(i, endc));
        i = endc;
        continue;
      }
      if ((lang === "js" || lang === "c" || lang === "gleam") && starts(src, i, "//")) {
        var nl4 = src.indexOf("\n", i);
        var end4 = nl4 === -1 ? n : nl4;
        out += span("tok-cmt", src.slice(i, end4));
        i = end4;
        continue;
      }
      if (lang === "sql" && starts(src, i, "--")) {
        var nl5 = src.indexOf("\n", i);
        var end5 = nl5 === -1 ? n : nl5;
        out += span("tok-cmt", src.slice(i, end5));
        i = end5;
        continue;
      }
      if (lang === "shell" && ch === "#") {
        var nl6 = src.indexOf("\n", i);
        var end6 = nl6 === -1 ? n : nl6;
        out += span("tok-cmt", src.slice(i, end6));
        i = end6;
        continue;
      }
      if (ch === '"' || ch === "'" || (lang === "elixir" && starts(src, i, '"""'))) {
        var triple = lang === "elixir" && starts(src, i, '"""');
        var q = triple ? '"""' : ch;
        var j = i + q.length;
        while (j < n) {
          if (src[j] === "\\" && !triple) { j += 2; continue; }
          if (src.slice(j, j + q.length) === q) { j += q.length; break; }
          j += 1;
        }
        out += span("tok-str", src.slice(i, j));
        i = j;
        continue;
      }
      if (lang === "elixir" && ch === ":" && /[A-Za-z_]/.test(src[i + 1] || "")) {
        var k = i + 1;
        while (k < n && /[A-Za-z0-9_!?]/.test(src[k])) k += 1;
        out += span("tok-atom", src.slice(i, k));
        i = k;
        continue;
      }
      if (/[0-9]/.test(ch) && (i === 0 || /[^A-Za-z_]/.test(src[i - 1]))) {
        var m = i + 1;
        while (m < n && /[0-9_]/.test(src[m])) m += 1;
        out += span("tok-num", src.slice(i, m));
        i = m;
        continue;
      }
      if (/[A-Za-z_]/.test(ch)) {
        var w = i + 1;
        while (w < n && /[A-Za-z0-9_!?-]/.test(src[w])) w += 1;
        var word = src.slice(i, w);
        var low = word.toLowerCase();
        if (kw[word] || kw[low] && (lang === "sql" || lang === "css")) out += span("tok-kw", word);
        else if (lang === "erlang" && /^[A-Z]/.test(word)) out += span("tok-atom", word);
        else out += esc(word);
        i = w;
        continue;
      }
      out += esc(ch);
      i += 1;
    }
    return out;
  }

  function langOf(code) {
    var cls = code.className || "";
    var m = cls.match(/language-([a-z0-9]+)/);
    return m ? m[1] : "";
  }

  function enhanceCode() {
    var blocks = document.querySelectorAll("pre > code");
    for (var i = 0; i < blocks.length; i++) {
      var code = blocks[i];
      var pre = code.parentNode;
      if (pre.parentNode.classList && pre.parentNode.classList.contains("codeblock")) continue;
      var raw = code.textContent.replace(/\n$/, "");
      var lang = langOf(code);
      if (lang) code.innerHTML = highlight(raw, lang);
      var wrap = document.createElement("div");
      wrap.className = "codeblock";
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy";
      btn.textContent = "Copy";
      btn.addEventListener("click", function (source, button) {
        return function () {
          var done = function () {
            button.textContent = "Copied";
            setTimeout(function () { button.textContent = "Copy"; }, 1200);
          };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(source).then(done, function () { fallback(source); done(); });
          } else {
            fallback(source);
            done();
          }
        };
      }(raw, btn));
      wrap.appendChild(btn);
    }
  }

  function fallback(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.left = "-9999px";
    document.body.appendChild(area);
    area.select();
    try { document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(area);
  }

  function wireSearch() {
    var input = document.getElementById("q");
    var box = document.getElementById("results");
    var links = document.querySelectorAll(".contents a");
    if (!input || !box) return;
    var index = window.WG_SEARCH || [];

    function render(query) {
      var q = query.trim().toLowerCase();
      for (var i = 0; i < links.length; i++) {
        var label = links[i].textContent.toLowerCase();
        links[i].classList.toggle("dim", q.length > 0 && label.indexOf(q) === -1);
      }
      if (!q) {
        box.className = "results";
        box.innerHTML = "";
        return;
      }
      var hits = [];
      for (var j = 0; j < index.length; j++) {
        var item = index[j];
        var hay = (item.title + " " + item.text).toLowerCase();
        if (hay.indexOf(q) !== -1) hits.push(item);
        if (hits.length === 8) break;
      }
      if (!hits.length) {
        box.className = "results open";
        box.textContent = "No pages match.";
        return;
      }
      box.className = "results open";
      box.innerHTML = "";
      hits.forEach(function (hit) {
        var a = document.createElement("a");
        a.href = hit.href;
        var title = document.createElement("span");
        title.className = "hit-title";
        title.textContent = hit.title;
        var bit = document.createElement("span");
        bit.className = "hit-bit";
        var at = (hit.title + " " + hit.text).toLowerCase().indexOf(q);
        var src = hit.text || hit.title;
        var start = Math.max(0, at - 24);
        bit.textContent = (start ? "…" : "") + src.slice(start, start + 90);
        a.appendChild(title);
        a.appendChild(bit);
        box.appendChild(a);
      });
    }

    input.addEventListener("input", function () { render(input.value); });
  }

  document.addEventListener("DOMContentLoaded", function () {
    enhanceCode();
    wireSearch();
  });
})();
