tea.run({
  init() {
    this.count = 7;
  },

  update(msg) {
    if (msg.kind === "key") {
      switch (msg.key.code) {
        case "q":
          return tea.quit();
        case "up":
          return this.count++;
        case "down":
          return this.count--;
        case "r":
          return (this.count = 0);
      }
    }
  },

  view() {
    return h(
      "col",
      { gap: 1 },
      h("box", { bold: true, fg: "#00ffff", border: "rounded", width: 30, height: 3 }, `Counter: ${this.count}`),
      h("text", { fg: "#555555" }, "↑/↓/k/j  r=reset  q=quit"),
    );
  },
});
