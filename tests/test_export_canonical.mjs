// No mocks: serve actual exported HTML over HTTP and execute it in Chromium.
import {readFileSync, readdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {join, sep} from 'node:path';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {chromium} from './browser/node_modules/playwright/index.mjs';
const root = process.argv[2];
const paths = readdirSync(root, {recursive:true}).filter(path => path.endsWith('index.html'));
assert.equal(paths.length, 3);
const allowed = new Map(paths.map(path => ['/' + path.split(sep).join('/'), path]));
const server = createServer((request,response) => {
  const path = allowed.get(decodeURIComponent(new URL(request.url,'http://localhost').pathname));
  if (!path) {response.writeHead(404).end();return;}
  response.writeHead(200, {'content-type':'text/html'}).end(readFileSync(join(root,path)));
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
let browser;
try {
  browser = await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || execFileSync('which',['chromium'],{encoding:'utf8'}).trim(),args:['--no-sandbox']});
  for (const path of allowed.keys()) {
    const page = await browser.newPage();
    const errors=[]; page.on('pageerror', error=>errors.push(error.message));
    const response=await page.goto(`http://127.0.0.1:${server.address().port}${path}`);
    assert.equal(response.status(),200);
    assert.deepEqual(await page.evaluate(()=>({
      literal:globalThis.headLiteral,open:globalThis.openLiteral,
      double:globalThis.doubleLiteral,afterDouble:globalThis.afterDouble,
      links:[...document.head.querySelectorAll('link')].filter(link=>link.rel.toLowerCase().split(/\s+/).includes('canonical')).map(link=>({
        href:link.href, hk:link.getAttribute('data-hk'), test:link.getAttribute('data-test'),
        nonce:link.nonce, ownHk:Object.hasOwn(link.dataset,'hk'),
      })),
      headCount:document.querySelectorAll('head').length,
    })), {literal:'</head>',open:'</nope',double:'</script>',afterDouble:'</head>',links:[{
      href:'https://example.test/markup',hk:'r3',test:'a>b',nonce:'n',ownHk:true,
    }],headCount:1});
    assert.deepEqual(errors,[]);
    await page.close();
  }
} finally {
  if (browser) await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
console.log('canonical export HTTP/Chromium preservation passed');
