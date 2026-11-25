// Chebit handbook page: the theme toggle, and the handbook from handbook-data.js.
// No dependencies. The text comes from docs/HANDBOOK.md and is never written here.

// ---------- theme ----------
// The same choice as the landing page, in the same storage key.
document.getElementById("theme-toggle").addEventListener("click", function () {
  const root = document.documentElement;
  const nextTheme = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = nextTheme;
  try {
    localStorage.setItem("chebit-theme", nextTheme);
  } catch (error) {
    // Storage can be blocked. The toggle still works for this visit.
  }
});

// ---------- handbook ----------
(function () {
  const raw = window.CHEBIT_HANDBOOK;
  const byId = (id) => document.getElementById(id);

  if (typeof raw !== "string" || raw.indexOf("### 1. ") === -1) {
    byId("missing").hidden = false;
    return;
  }

  // ----- the subset of Markdown that the handbook uses -----
  const escapeHtml = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  // Code spans first, so a `*` inside code is never read as bold. R1 to R9 link to a finding.
  function inline(text) {
    return text
      .split("`")
      .map(function (part, index) {
        if (index % 2) return "<code>" + escapeHtml(part) + "</code>";
        return escapeHtml(part)
          .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
          .replace(/\bR([1-9])\b/g, '<a href="#R$1">R$1</a>');
      })
      .join("");
  }

  const cells = (row) => row.split("|").slice(1, -1).map((cell) => cell.trim());

  // Paragraphs, `- ` lists with wrapped lines, and fenced code.
  function blocks(markdown) {
    const out = [];
    const lines = markdown.split("\n");
    let paragraph = [];
    let list = null;

    function flushParagraph() {
      if (paragraph.length) out.push("<p>" + inline(paragraph.join(" ")) + "</p>");
      paragraph = [];
    }

    function flushList() {
      if (list) out.push("<ul>" + list.map((item) => "<li>" + inline(item) + "</li>").join("") + "</ul>");
      list = null;
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];

      if (line.startsWith("```")) {
        flushParagraph();
        flushList();
        const code = [];
        for (i++; i < lines.length && !lines[i].startsWith("```"); i++) code.push(lines[i]);
        out.push("<pre><code>" + escapeHtml(code.join("\n")) + "</code></pre>");
      } else if (line.startsWith("- ")) {
        flushParagraph();
        (list = list || []).push(line.slice(2));
      } else if (list && /^\s{2,}\S/.test(line)) {
        list[list.length - 1] += " " + line.trim();
      } else if (line.trim() === "") {
        flushParagraph();
        flushList();
      } else {
        flushList();
        paragraph.push(line.trim());
      }
    }

    flushParagraph();
    flushList();
    return out.join("");
  }

  // ----- read the handbook: a practice starts at `### N. Title`, a section at `## Title` -----
  const practices = [];
  const sections = {};
  const intro = [];
  let part = null;
  let current = null;
  let section = null;

  raw.split("\n").forEach(function (line) {
    const heading = /^### (\d+)\. (.+)$/.exec(line);

    if (line.startsWith("## ")) {
      const title = line.slice(3);
      current = null;
      if (title.startsWith("Part ")) {
        part = title;
        section = null;
      } else {
        part = null;
        section = title;
        sections[section] = [];
      }
    } else if (heading) {
      current = { id: Number(heading[1]), title: heading[2], part: part, body: [] };
      practices.push(current);
    } else if (current) {
      current.body.push(line);
    } else if (section) {
      sections[section].push(line);
    } else {
      intro.push(line);
    }
  });

  const LABEL = /^\*\*(Status:|Rule\.|Failure it prevents\.|In Chebit\.|Proof\.|Gaps\.)\*\*[ ]?/gm;
  const STATUS_NAMES = { done: "Done", partial: "Partial", notyet: "Not yet" };

  practices.forEach(function (practice) {
    const text = practice.body.join("\n");
    const marks = [];
    let match;

    LABEL.lastIndex = 0;
    while ((match = LABEL.exec(text))) {
      marks.push({ label: match[1].replace(/[.:]$/, ""), start: match.index, end: LABEL.lastIndex });
    }

    practice.segments = marks.map(function (mark, index) {
      const end = index + 1 < marks.length ? marks[index + 1].start : text.length;
      return { label: mark.label, markdown: text.slice(mark.end, end).trim() };
    });

    const status = (practice.segments.find((segment) => segment.label === "Status") || { markdown: "" }).markdown;
    practice.status = status.startsWith("Done") ? "done" : status.startsWith("Partial") ? "partial" : "notyet";
    practice.statusName = STATUS_NAMES[practice.status];
    practice.note = status.replace(/^(Done|Partial|Not yet)\s*/, "").replace(/^\((.*)\)$/, "$1");
    practice.search = (practice.title + " " + text).toLowerCase();
  });

  // ----- counts -----
  const counts = { all: practices.length, done: 0, partial: 0, notyet: 0 };
  practices.forEach((practice) => counts[practice.status]++);
  document.querySelectorAll("[data-count]").forEach(function (element) {
    element.textContent = counts[element.dataset.count];
  });

  // ----- one coin for each practice -----
  byId("coins").innerHTML = practices
    .map(function (practice) {
      const title = practice.id + ". " + practice.title + " (" + practice.statusName + ")";
      return '<a class="coin ' + practice.status + '" href="#p' + practice.id + '" title="' + escapeHtml(title) +
        '" aria-label="' + escapeHtml(title) + '"></a>';
    })
    .join("");

  // ----- the practices, by part -----
  const groups = [];
  practices.forEach(function (practice) {
    let last = groups[groups.length - 1];
    if (!last || last.name !== practice.part) groups.push((last = { name: practice.part, items: [] }));
    last.items.push(practice);
  });

  const parts = byId("parts");
  parts.innerHTML = groups
    .map(function (group) {
      const rows = group.items
        .map(function (practice) {
          const detail = practice.segments
            .filter((segment) => segment.label !== "Status")
            .map((segment) => "<dt>" + segment.label + "</dt><dd>" + blocks(segment.markdown) + "</dd>")
            .join("");
          const note = practice.note ? '<p class="hb-note">' + inline(practice.note) + "</p>" : "";

          return '<details class="hb-practice" id="p' + practice.id + '">' +
            '<summary><i class="coin ' + practice.status + '"></i><span class="hb-num">' + practice.id + "</span>" +
            '<span class="hb-title">' + inline(practice.title) + '</span><span class="hb-state">' + practice.statusName +
            '</span></summary><dl class="hb-detail">' + note + detail + "</dl></details>";
        })
        .join("");

      return '<div class="hb-part"><h3>' + escapeHtml(group.name || "") + "</h3>" + rows + "</div>";
    })
    .join("");

  // ----- filter and search -----
  const search = byId("search");
  const buttons = Array.from(document.querySelectorAll("[data-filter]"));
  let filter = "all";

  function apply() {
    const words = search.value.toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0;

    practices.forEach(function (practice) {
      const visible = (filter === "all" || practice.status === filter) &&
        words.every((word) => practice.search.includes(word));
      byId("p" + practice.id).hidden = !visible;
      if (visible) shown++;
    });

    parts.querySelectorAll(".hb-part").forEach(function (group) {
      group.hidden = !group.querySelector(".hb-practice:not([hidden])");
    });
    byId("empty").hidden = shown !== 0;
  }

  buttons.forEach(function (button) {
    button.addEventListener("click", function () {
      filter = button.dataset.filter;
      buttons.forEach((other) => other.setAttribute("aria-pressed", String(other === button)));
      apply();
    });
  });
  search.addEventListener("input", apply);

  // A link to #p13 opens practice 13, also when a filter hides it.
  function openTarget() {
    const target = document.getElementById(location.hash.slice(1));
    if (!target || !target.classList.contains("hb-practice")) return;
    if (target.hidden) {
      search.value = "";
      buttons[0].click();
    }
    target.open = true;
    target.scrollIntoView();
  }
  window.addEventListener("hashchange", openTarget);

  // ----- review findings: a paragraph, a table, a closing paragraph -----
  const findings = (sections["Review findings"] || []).join("\n").trim().split(/\n\s*\n/);
  const prose = findings.filter((chunk) => !chunk.startsWith("|"));
  const table = findings.find((chunk) => chunk.startsWith("|"));

  byId("findings-intro").innerHTML = inline((prose[0] || "").replace(/\n/g, " "));
  byId("findings-after").innerHTML = inline((prose[1] || "").replace(/\n/g, " "));

  if (table) {
    const rows = table.split("\n");
    const head = cells(rows[0]);
    const body = rows.slice(2).map(function (row) {
      const c = cells(row);
      const where = c[4].split(",").map((n) => '<a href="#p' + n.trim() + '">' + n.trim() + "</a>").join(", ");

      return '<tr id="' + escapeHtml(c[0]) + '"><td class="id">' + escapeHtml(c[0]) + "</td>" +
        '<td class="severity ' + escapeHtml(c[1].toLowerCase()) + '" data-label="' + head[1] + '">' + escapeHtml(c[1]) + "</td>" +
        '<td data-label="' + head[2] + '">' + inline(c[2]) + "</td>" +
        '<td data-label="' + head[3] + '">' + inline(c[3]) + "</td>" +
        '<td class="where" data-label="' + head[4] + '">' + where + "</td>" +
        '<td data-label="' + (head[5] || "State") + '">' + inline(c[5] || "") + "</td></tr>";
    });

    byId("findings-table").innerHTML = '<table class="hb-table"><thead><tr>' +
      head.map((title) => "<th>" + escapeHtml(title) + "</th>").join("") + "</tr></thead><tbody>" + body.join("") +
      "</tbody></table>";
  }

  // ----- the commands come from the code block of the MCP practice -----
  const mcp = practices.find((practice) => /MCP/.test(practice.title));
  const fence = mcp && /```[a-z]*\n([\s\S]*?)\n```/.exec(mcp.body.join("\n"));
  const commands = byId("commands");
  commands.textContent = fence ? fence[1] : "See docs/HANDBOOK.md, practice 37.";

  byId("copy").addEventListener("click", function () {
    const button = this;
    const done = function () {
      button.textContent = "Copied";
      setTimeout(() => (button.textContent = "Copy commands"), 1600);
    };

    if (navigator.clipboard) {
      navigator.clipboard.writeText(commands.textContent).then(done);
    } else {
      const range = document.createRange();
      range.selectNodeContents(commands);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      document.execCommand("copy");
      done();
    }
  });

  // ----- the state line of the handbook, under the hero -----
  const state = intro.join("\n").match(/\*\*State of the code:\*\* ([^\n]+)/);
  if (state) byId("state").innerHTML = "State of the code: " + inline(state[1]);

  apply();
  openTarget();
})();
