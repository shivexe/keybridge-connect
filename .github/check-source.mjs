import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const version = readFileSync('VERSION', 'utf8').trim();
if (!/^\d+\.\d+\.\d+\+[1-9]\d*$/.test(version)) throw new Error('Invalid VERSION');
const [name, build] = version.split('+');
const android = readFileSync('apps/android/pubspec.yaml', 'utf8').match(/^version:\s*(.+)$/m)?.[1];
const plist = readFileSync('apps/macos/Info.plist', 'utf8');
const plistValue = key => plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))?.[1];
if (android !== version || plistValue('CFBundleShortVersionString') !== name || plistValue('CFBundleVersion') !== build) {
  throw new Error('VERSION, Android version, and Mac version/build must match');
}
if (process.env.RELEASE_TAG && process.env.RELEASE_TAG !== `v${name}`) throw new Error('Tag/version mismatch');
const files = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const forbidden = /(^|\/)(\.work|\.tools|tools|references|artifacts|build|\.build|\.dart_tool|\.gradle|node_modules|xcuserdata)(\/|$)|(?:overnight|piid-|prompt.*\.md)|\.(?:apk|aab|dmg|jks|keystore|p12|p8|mobileprovision|provisionprofile|zip|tar\.gz|log)$/i;
const allowedDocs = new Set(['docs/INSTALL.md', 'docs/RELEASING.md']);
for (const file of files) {
  if (forbidden.test(file) || (file.startsWith('docs/') && !allowedDocs.has(file))) {
    throw new Error(`Private/generated path is tracked: ${file}`);
  }
  if (/\.(png|icns)$/.test(file)) continue;
  const text = readFileSync(file, 'utf8');
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\r\n]/.test(text) || /\bgh[pousr]_[A-Za-z0-9]{30,}\b/.test(text) || /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/.test(text)) {
    throw new Error(`Potential credential in tracked file: ${file}`);
  }
  if (/\/home\/notsg\/|\/Users\/notsg\//.test(text)) throw new Error(`Machine-specific path in ${file}`);
}
console.log(`Validated ${files.length} tracked files; version ${version}`);
