import { milktea, h } from "milktea";

milktea.run({
  init() {
    this.count = 0;
  },
  update(msg) {
    if (msg.kind === "key") {
      switch (msg.code) {
        case "q": return milktea.quit();
        case "up":   this.count++; break;
        case "down": this.count--; break;
        case "r":    this.count = 0; break;
      }
    }
  },
  view() {
    return h("col", { gap: 1 },
      h("box", { bold: true, fg: "#00ffff", border: "rounded", width: 30, height: 3 },
        "Counter: ", this.count),
      h("text", { fg: "#555555" }, "↑/↓  r=reset  q=quit"),
    );
  },
});
