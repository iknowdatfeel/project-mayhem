"use strict";
"require baseclass";
"require form";
"require uci";
"require rpc";
"require ui";
"require mayhem.common as mh";
"require mayhem.diag as diag";
"require dom";
"require mayhem.page.sections as routing";
"require mayhem.page.mux as mux";
"require mayhem.page.components as components";
"require mayhem.dash.conns as conns";

// Settings: logging, memory, watchdog, server checks and the reset to defaults.

const callReset = rpc.declare({
  object: "luci.mayhem",
  method: "reset_config",
  params: ["connections"],
  expect: { "": {} },
});

function resetDialog() {
  const keep = E("input", { type: "checkbox", checked: "" });

  ui.showModal(_("Restore defaults"), [
    E(
      "p",
      _(
        "Every setting of Mayhem goes back to how it was after installation: sections, rules, DNS, geo sources. Xray restarts.",
      ),
    ),
    E("label", [keep, " ", _("Keep subscriptions, server keys and HWID")]),
    E("div", { class: "right", style: "margin-top:1em" }, [
      E("button", { class: "btn", click: ui.hideModal }, _("Cancel")),
      " ",
      E(
        "button",
        {
          class: "btn cbi-button-negative",
          click: ui.createHandlerFn(this, () =>
            callReset(keep.checked).then((r) => {
              if (r.error) {
                ui.addNotification(null, E("p", r.error), "error");
                return;
              }

              ui.hideModal();
              ui.addNotification(
                null,
                E(
                  "p",
                  _(
                    "The settings are reset. The page reloads in a few seconds.",
                  ),
                ),
                "info",
              );
              window.setTimeout(() => window.location.reload(), 3000);
            }),
          ),
        },
        _("Reset settings"),
      ),
    ]),
  ]);
}

return baseclass.extend({
  load() {
    return uci.load("mayhem");
  },

  unload() {
    if (this.stopTab) this.stopTab();
    this.stopTab = null;
    this.root = null;
  },

  // Validate every opened tab before saving their shared UCI cache.
  handleSave() {
    const maps = Array.from(this.root.querySelectorAll(".cbi-map")).map(
      (node) => dom.findClassInstance(node),
    );
    maps.forEach((map) => map.checkDepends());
    return maps
      .reduce((p, map) => p.then(() => map.parse()), Promise.resolve())
      .then(() => uci.save())
      .then(() =>
        Promise.all(maps.map((map) => map.load().then(() => map.reset()))),
      )
      .catch((e) => {
        ui.addNotification(null, E("p", e.message || String(e)), "error");
        throw e;
      });
  },

  handleSaveApply(ev, mode) {
    return this.handleSave().then(() => ui.changes.apply(mode == "0"));
  },

  handleReset() {
    return Array.from(this.root.querySelectorAll(".cbi-map")).reduce(
      (p, node) => p.then(() => dom.callClassMethod(node, "reset")),
      Promise.resolve(),
    );
  },

  render() {
    this.unload();
    const root = (this.root = E("div", { class: "mh-settings" }));
    let diagnosed = false;
    const tabs = [
      [
        "routing",
        _("Routing"),
        () => routing.load().then((data) => routing.render(data, "settings")),
      ],
      [
        "dns",
        _("DNS"),
        () => routing.load().then((data) => routing.render(data, "dns")),
      ],
      [
        "geo",
        _("Geo data"),
        () => routing.load().then((data) => routing.render(data, "geo")),
      ],
      ["mux", _("Multiplexing"), () => mux.load().then(() => mux.render())],
      [
        "connections",
        _("Active connections"),
        () => conns.content(),
        () => conns.start(),
        () => conns.stop(),
      ],
      [
        "components",
        _("Component updates"),
        () => components.load().then((data) => components.render(data)),
      ],
      [
        "diagnostics",
        _("Diagnostics"),
        () => diag.diagnosticContent(),
        () => {
          if (!diagnosed) {
            diagnosed = true;
            diag.run();
          } else diag.drawList();
        },
      ],
      ["main", _("Advanced"), () => this.renderMain()],
    ];
    const icons = {
      routing: "route",
      dns: "network",
      geo: "globe",
      mux: "zap",
      components: "package",
      connections: "activity",
      diagnostics: "search",
      main: "settings",
    };
    const bar = E("div", {
      class: "mh-settings-tabs",
      role: "tablist",
      "aria-label": _("Settings"),
    });
    const row = E("div", {
      class: "mh-settings-tabrow",
      role: "presentation",
    });
    bar.appendChild(row);
    let active = null;
    const activate = (tab) => {
      if (active === tab) return tab.loading || Promise.resolve();
      if (this.stopTab) this.stopTab();
      this.stopTab = null;
      active = tab;
      tabs.forEach((t) => {
        const selected = t === tab;
        t.button.setAttribute("aria-selected", String(selected));
        t.button.tabIndex = selected ? 0 : -1;
        t.pane.hidden = !selected;
      });
      if (!tab.loading) {
        tab.pane.replaceChildren(E("p", { class: "spinning" }, _("Loading…")));
        tab.loading = Promise.resolve()
          .then(tab[2])
          .then((node) => {
            tab.pane.replaceChildren(node);
          })
          .catch((e) => {
            tab.loading = null;
            tab.pane.replaceChildren(
              E("p", { class: "mh-fail" }, String(e.message || e)),
            );
            throw e;
          });
      }
      return tab.loading
        .then(() => {
          if (active !== tab || this.root !== root || !tab[3]) return;
          this.stopTab = tab[4] || null;
          tab[3]();
        })
        .catch(() => {});
    };
    tabs.forEach((tab, i) => {
      tab.pane = E("div", {
        id: "mh-settings-" + tab[0],
        role: "tabpanel",
        "aria-labelledby": "mh-settings-tab-" + tab[0],
        hidden: "",
      });
      tab.button = E(
        "button",
        {
          id: "mh-settings-tab-" + tab[0],
          type: "button",
          role: "tab",
          "aria-controls": tab.pane.id,
          "aria-selected": "false",
          tabindex: "-1",
          click: () => activate(tab),
          keydown: (ev) => {
            let next;
            if (ev.key === "ArrowRight") next = (i + 1) % tabs.length;
            else if (ev.key === "ArrowLeft")
              next = (i + tabs.length - 1) % tabs.length;
            else if (ev.key === "Home") next = 0;
            else if (ev.key === "End") next = tabs.length - 1;
            else return;
            ev.preventDefault();
            tabs[next].button.focus();
            activate(tabs[next]);
          },
        },
        [mh.icon(icons[tab[0]], true), E("span", tab[1])],
      );
      row.appendChild(tab.button);
    });
    root.appendChild(
      E(
        "style",
        `
.mh-settings-tabs { display:flex; overflow-x:auto; gap:4px; border-bottom:1px solid var(--border-color-low, #ddd); margin-bottom:16px; }
.mh-settings-tabrow { display:flex; flex-wrap:nowrap; justify-content:flex-start; gap:4px; }
.mh-settings-tabs [role=tab] { display:inline-flex; flex-shrink:0; white-space:nowrap; align-items:center; gap:6px; background:none; color:inherit; border:0; border-bottom:3px solid transparent; padding:6px 6px; cursor:pointer; }
.mh-settings-tabs [aria-selected=true] { border-bottom-color:var(--primary-color-high, #37c); font-weight:bold; }
.mh-settings > [role=tabpanel] { contain:inline-size; }
.mh-settings > [role=tabpanel][hidden] { display:none; }
@media (max-width: 600px) {
.mh-settings-tabs { overflow:visible; }
.mh-settings-tabrow { flex-wrap:wrap; min-width:0; }
.mh-settings-tabs [role=tab] { flex-shrink:1; min-width:0; max-width:100%; white-space:normal; text-align:left; }
.mh-settings-tabs [role=tab] span { min-width:0; overflow-wrap:anywhere; }
}
`,
      ),
    );
    root.appendChild(bar);
    tabs.forEach((tab) => root.appendChild(tab.pane));
    return activate(tabs[0]).then(() => root);
  },

  renderMain() {
    const m = new form.Map("mayhem");
    let s, o;

    s = m.section(form.NamedSection, "settings", "settings");
    s.addremove = false;

    o = s.option(
      form.Value,
      "memlimit",
      _("Xray memory limit (GOMEMLIMIT), MiB"),
      _(
        "A soft limit: Xray frees memory more often when it gets close. Empty: a quarter of the router memory.",
      ),
    );
    o.datatype = "range(16,4096)";
    o.placeholder = _("Auto");

    o = s.option(
      form.Flag,
      "watchdog",
      _("Watchdog"),
      _(
        "Restarts Xray when it holds too much memory for 3 minutes in a row, and dnsmasq when it is gone.",
      ),
    );
    o.default = "1";
    o.rmempty = false;

    o = s.option(
      form.ListValue,
      "watchdog_mem",
      _("Watchdog memory threshold"),
    );
    [30, 40, 50, 60].forEach((p) =>
      o.value(String(p), _("%d%% of memory").format(p)),
    );
    o.default = "40";
    o.depends("watchdog", "1");

    o = s.option(
      form.Value,
      "probe_url",
      _("URLTest URL"),
      _(
        "The automatic server choice and the URL test request it through each server.",
      ),
    );
    o.placeholder = "http://www.gstatic.com/generate_204";
    o.validate = function (section_id, value) {
      return !value || /^https?:\/\/\S+$/.test(value)
        ? true
        : _("Expected an http(s):// address");
    };

    o = s.option(
      form.ListValue,
      "probe_interval",
      _("URLTest interval"),
      _(
        "With many servers the checks are spread out: at least two seconds per server, so 150 servers are checked every 5 minutes.",
      ),
    );
    o.value("1m", _("Every minute"));
    o.value("3m", _("Every 3 minutes"));
    o.value("5m", _("Every 5 minutes"));
    o.value("10m", _("Every 10 minutes"));
    o.value("30m", _("Every 30 minutes"));
    o.default = "3m";

    o = s.option(
      form.Value,
      "ip_check_url",
      _("External IP check URL"),
      _(
        "Diagnostics request it directly and through every section; it must answer with the IP address as plain text.",
      ),
    );
    o.placeholder = "https://api.ipify.org";
    o.validate = function (section_id, value) {
      return !value || /^https?:\/\/\S+$/.test(value)
        ? true
        : _("Expected an http(s):// address");
    };

    o = s.option(
      form.Button,
      "_backup",
      _("Backup"),
      _("Export every setting of Mayhem to a file or restore them from one."),
    );
    o.inputtitle = _("Backup…");
    o.inputstyle = "action";
    o.onclick = () => diag.backup();

    o = s.option(form.Button, "_reset", _("Restore defaults"));
    o.inputtitle = _("Reset settings…");
    o.inputstyle = "negative";
    o.onclick = resetDialog;

    return m.render().then((node) => {
      node.insertBefore(mh.style(), node.firstChild);

      return node;
    });
  },
});
