// @jsx h

interface Tea<M extends TeaModel> {
  run: (app: TeaApp<M>) => void;
  quit: () => void;
}

interface TeaModel {}

interface JSX {}

interface TeaApp<M extends TeaModel> {
  init: () => void;
  update: (msg: TeaMessage) => void;
  view: () => JSX;
  [k: keyof M]: M[typeof k];
}

interface TeaMessage {
  kind: string;
  [k: string]: unknown;
}

interface TeaKeyMessage extends TeaMessage {
  kind: "key";
  code: string;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
}

declare var tea: Tea<{ count: number }>;

tea.run({
  init() {
    this.count = 0;
  },

  update(msg: { kind: string; [k: string]: unknown }) {
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
    return (
      <col gap={1}>
        <box bold fg="#00ffff" border="rounded" width={30} height={3}>
          Counter: {this.count}
        </box>
        <text fg="#555555">↑/↓/k/j r=reset q=quit</text>
      </col>
    );
  },
});
