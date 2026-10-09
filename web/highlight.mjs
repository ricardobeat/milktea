import highlight from './vendor/highlight-javascript.mjs';

// The vendored build includes only Highlight.js core and its JavaScript grammar.
// Keep the textarea overlay independent of the library's API and markup.
export function highlightJavaScript(source) {
  return highlight(source);
}
