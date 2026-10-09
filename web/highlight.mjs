// A small JavaScript colorizer for the editor overlay. It never executes code
// and escapes every token before inserting markup. Editing stays in a textarea.
const keywords = new Set('async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield'.split(' '));
const literals = new Set(['true','false','null','undefined','NaN','Infinity']);
const builtins = new Set(['Array','Boolean','Date','Error','JSON','Map','Math','Number','Object','Promise','RegExp','Set','String','console']);
const tokens = /\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|$)|"(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)|`(?:\\[\s\S]|[^`\\])*(?:`|$)|\b(?:0[xX][\da-fA-F]+|0[bB][01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?n?)\b|[$\p{L}_][$\p{L}\p{N}_]*|[{}()[\];,.]|[+\-*\/%=<>!&|?:]+/gu;
const escape = value => value.replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
export function highlightJavaScript(source) {
  let html='', end=0;
  for (const match of source.matchAll(tokens)) {
    const token=match[0];
    html+=escape(source.slice(end,match.index));
    const type=token.startsWith('//') || token.startsWith('/*') ? 'comment'
      : /^["'`]/.test(token) ? 'string'
      : /^\d/.test(token) ? 'number'
      : keywords.has(token) ? 'keyword'
      : literals.has(token) ? 'literal'
      : builtins.has(token) ? 'builtin'
      : /^[{}()[\];,.]$/.test(token) ? 'punctuation'
      : /^[+\-*\/%=<>!&|?:]+$/.test(token) ? 'operator' : null;
    html+=type ? `<span class="token-${type}">${escape(token)}</span>` : escape(token);
    end=match.index+token.length;
  }
  return html+escape(source.slice(end));
}
