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

const files = [
  '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js',
  '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js',
];
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
