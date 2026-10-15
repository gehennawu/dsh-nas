#!/usr/bin/env node

import fs from 'node:fs';

const rawDomain = process.argv[2];
const trimmedDomain = rawDomain?.trim();
const domain = trimmedDomain?.toLowerCase();

if (!domain) {
  console.error('用法: node patch-trusted-domain.mjs <hostname>');
  process.exit(2);
}

if (rawDomain !== trimmedDomain) {
  console.error('DSH_TRUSTED_DOMAIN 不能包含首尾空白字符');
  process.exit(2);
}

if (
  domain.includes('://') ||
  domain.includes('/') ||
  domain.includes(':') ||
  /[\s"'\\]/u.test(domain) ||
  !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(domain)
) {
  console.error(
    `DSH_TRUSTED_DOMAIN 必须是单个纯 hostname（不含协议、端口或路径），实际为: ${JSON.stringify(domain)}`,
  );
  process.exit(2);
}

// alpha.3 把 client bundle 按运行平台拆分为 client.browser.js 与 client.node.js
// （更早版本是单一 client.js）；npm 也可能把 dsh-client-connection 提升到全局
// node_modules 根而非嵌套在 dsh 包内。这里按候选顺序解析出唯一同时包含全部
// 目标文件的 lib 目录；找不到时整个构建失败，绝不留下只 patch 一半的镜像层。
const libBases = [
  '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib',
  '/usr/local/lib/node_modules/@deepseek-ai/dsh-client-connection/lib',
];
const clientVariants = [
  ['client.browser.js', 'client.node.js'], // alpha.3+：按平台拆分的 client bundle
  ['client.js'], // alpha.2 及更早：单一共享 client bundle
];
const indexBundle = 'index.js'; // Host API 侧 loopback 栅栏
let resolved;
for (const base of libBases) {
  for (const clientFiles of clientVariants) {
    const names = [...clientFiles, indexBundle];
    if (names.every((name) => fs.existsSync(`${base}/${name}`))) {
      resolved = { base, files: names.map((name) => `${base}/${name}`) };
      break;
    }
  }
  if (resolved) break;
}
if (!resolved) {
  throw new Error(
    `DSH trusted-domain patch 未找到同时包含 client bundle（${clientVariants
      .map((variant) => variant.join(' + '))
      .join(' 或 ')}）与 ${indexBundle} 的目录，已搜索: ${libBases.join(' , ')}`,
  );
}
const files = resolved.files;
const marker = 'dsh-nas: trusted-domain patch';
const declaration = /(function isLoopbackHostname\(hostname\)\s*\{)/g;
const injected = ` if (hostname === ${JSON.stringify(domain)}) return true; // ${marker}`;
const prepared = [];

// 先把所有目标读取并校验完，再写入；升级导致任一 bundle 结构变化时整个构建失败，
// 不留下只 patch 一半的镜像层。
for (const file of files) {
  if (!fs.existsSync(file)) {
    throw new Error(`DSH trusted-domain patch 目标不存在: ${file}`);
  }

  const source = fs.readFileSync(file, 'utf8');
  if (source.includes(marker)) {
    throw new Error(`DSH trusted-domain patch 目标已被修改，拒绝重复 patch: ${file}`);
  }

  const matches = [...source.matchAll(declaration)];
  if (matches.length !== 1) {
    throw new Error(
      `DSH trusted-domain patch 预期在 ${file} 找到 1 个 isLoopbackHostname，实际找到 ${matches.length} 个`,
    );
  }

  prepared.push({ file, patched: source.replace(declaration, `$1${injected}`) });
}

for (const { file, patched } of prepared) {
  fs.writeFileSync(file, patched);

  const verified = fs.readFileSync(file, 'utf8');
  if (!verified.includes(injected)) {
    throw new Error(`DSH trusted-domain patch 写入后校验失败: ${file}`);
  }

  console.log(`DSH trusted-domain patch: ${file} 接受 ${domain}`);
}
