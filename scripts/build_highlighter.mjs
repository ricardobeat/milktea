// Optional maintenance build; serving the checked-in bundle needs no npm tools.
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {writeFile} from 'node:fs/promises';
const require=createRequire(process.env.MILKTEA_HIGHLIGHT_PACKAGE || import.meta.url);
const {build}=require('esbuild');
const core=require.resolve('highlight.js/lib/core');
const javascript=require.resolve('highlight.js/lib/languages/javascript');
const {version}=require('highlight.js/package.json');
const bundle=fileURLToPath(new URL('../web/vendor/highlight-javascript.mjs',import.meta.url));
await build({
  stdin:{contents:`import hljs from ${JSON.stringify(core)};
import javascript from ${JSON.stringify(javascript)};
hljs.registerLanguage('javascript', javascript);
export default source => hljs.highlight(source, {language:'javascript', ignoreIllegals:true}).value;`,
    resolveDir:fileURLToPath(new URL('.',import.meta.url))},
  outfile:bundle,bundle:true,minify:true,format:'esm',target:'es2020',legalComments:'inline',
  banner:{js:`// Highlight.js ${version}, core + JavaScript only. BSD-3-Clause; see highlight-javascript.LICENSE.\n// Rebuild with scripts/build_highlighter.mjs; no runtime network dependencies.`}
});
const license=require.resolve('highlight.js/package.json').replace(/package\.json$/, 'LICENSE');
const {readFile}=await import('node:fs/promises');
await writeFile(bundle.replace(/\.mjs$/,'.LICENSE'),await readFile(license));
const {gzipSync}=await import('node:zlib');
const data=await readFile(bundle);
console.log(`Highlight.js ${version}: ${data.length} bytes, ${gzipSync(data).length} bytes gzip`);
