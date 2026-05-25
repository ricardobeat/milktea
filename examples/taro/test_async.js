// test_async.js — full async test suite: timers, Promises, fetch
let passed = 0, failed = 0;

function assert(cond, name) {
  if (cond) {
    passed++;
  } else {
    failed++;
    console.log("FAIL: " + name);
  }
}

// --- Timer tests ---
setTimeout(() => assert(true, "setTimeout 0 fires"), 0);
setTimeout(() => assert(true, "setTimeout 10ms fires"), 10);

let cancel_id = setTimeout(() => assert(false, "cleared timeout must not fire"), 5);
clearTimeout(cancel_id);

let order = [];
setTimeout(() => { order.push("a"); }, 20);
setTimeout(() => { order.push("b"); }, 10);
setTimeout(() => {
  assert(order[0] === "b" && order[1] === "a", "setTimeout fires in delay order");
}, 30);

// --- Promise tests ---
Promise.resolve(42).then(v => assert(v === 42, "Promise.resolve.then"));
Promise.reject("err").catch(e => assert(e === "err", "Promise.reject.catch"));

new Promise(resolve => setTimeout(() => resolve("async"), 5))
  .then(v => assert(v === "async", "Promise resolved from setTimeout"));

Promise.resolve(1)
  .then(v => v + 1)
  .then(v => assert(v === 2, "Promise chain"));

// Promise.all
Promise.all([
  Promise.resolve("x"),
  new Promise(r => setTimeout(() => r("y"), 15)),
]).then(([a, b]) => assert(a === "x" && b === "y", "Promise.all"));

// --- fetch tests ---
fetch("http://httpbin.org/get")
  .then(r => {
    assert(r.ok, "fetch GET ok=true");
    assert(r.status === 200, "fetch GET status=200");
    return r.text();
  })
  .then(body => assert(body.includes("httpbin"), "fetch GET body contains 'httpbin'"))
  .catch(() => assert(false, "fetch should not reject on valid URL"));

// fetch invalid host — should reject
fetch("http://this-host-does-not-exist-taro-test.invalid/")
  .then(() => assert(false, "fetch invalid host should reject"))
  .catch(e => assert(typeof e === "string", "fetch invalid host rejects with string error"));

// --- Final report ---
setTimeout(() => {
  console.log("Async tests: " + passed + " passed, " + failed + " failed");
  if (failed === 0) console.log("ALL PASSED");
  return milktea.quit();
}, 3000);

milktea.run({
  init() {},
  update(msg) {
    if (msg.kind === "key" && msg.code === "q") return milktea.quit();
  },
  view() {
    return h("col", {},
      h("text", {}, "Running async tests... (q to abort)"),
      h("text", { fg: "#888888" }, "passed=" + passed + " failed=" + failed),
    );
  },
});
