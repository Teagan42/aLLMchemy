// Validates intake.yaml against intake.schema.json and prints the resolved values with
// defaults applied. Phase 0's first step: nothing else in the tree reads the schema, so
// without this `price_usd: 500` or `audience_region: EU` passes straight into Phase 2 and
// the product is designed to a ceiling or a consent rule the operator never asked for.
//
//   node bin/validate-intake.mjs [intake.yaml]        exit 0 valid, 1 invalid, 2 unreadable
//   node bin/validate-intake.mjs --json               resolved values as JSON on stdout
//
// Node ESM, zero dependencies, same no-install rule as template/billing-core. A missing
// intake file is valid: every property has a default and an empty submission is legal.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2).filter((a) => a !== '--json');
const asJson = process.argv.includes('--json');
const intakePath = resolve(args[0] ?? resolve(HERE, '..', 'intake.yaml'));
const schemaPath = resolve(HERE, '..', 'intake.schema.json');

// Flat `key: value` only, which is the whole shape intake.schema.json permits. Nesting or a
// list is reported rather than silently ignored — a quietly dropped key is the failure this
// script exists to prevent.
export function parseFlatYaml(text) {
  const out = {};
  const problems = [];
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.replace(/\s+#.*$/, '').replace(/^#.*$/, '');
    if (!line.trim()) return;
    if (/^\s/.test(line) || /^-/.test(line.trim())) {
      problems.push(`line ${i + 1}: nested or list syntax is not supported in intake.yaml`);
      return;
    }
    const m = /^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/.exec(line);
    if (!m) {
      problems.push(`line ${i + 1}: not \`key: value\`: ${raw.trim()}`);
      return;
    }
    out[m[1]] = coerce(m[2].trim());
  });
  return { values: out, problems };
}

const coerce = (v) => {
  if (v === '') return '';
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
    return v.slice(1, -1);
  }
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return v;
};

// Covers exactly the keywords intake.schema.json uses. A general JSON Schema engine would
// be a dependency, and an unused keyword here is a silent gap, so unknown keywords throw.
const HANDLED = ['type', 'enum', 'minimum', 'maximum', 'maxLength', 'default', 'description'];

export function validate(values, schema) {
  const problems = [];
  const props = schema.properties ?? {};

  for (const key of Object.keys(values)) {
    if (!Object.prototype.hasOwnProperty.call(props, key)) {
      problems.push(`unknown field \`${key}\` (additionalProperties is false)`);
    }
  }

  const resolved = {};
  for (const [key, spec] of Object.entries(props)) {
    for (const kw of Object.keys(spec)) {
      if (!HANDLED.includes(kw)) throw new Error(`schema keyword \`${kw}\` is unimplemented`);
    }
    if (!Object.prototype.hasOwnProperty.call(values, key)) {
      resolved[key] = spec.default;
      continue;
    }
    const v = values[key];
    resolved[key] = v;
    const where = `\`${key}\``;

    if (spec.enum && !spec.enum.includes(v)) {
      problems.push(`${where}: ${JSON.stringify(v)} is not one of ${spec.enum.join(' | ')}`);
      continue;
    }
    if (spec.type === 'number' && typeof v !== 'number') {
      problems.push(`${where}: expected a number, got ${JSON.stringify(v)}`);
      continue;
    }
    if (spec.type === 'boolean' && typeof v !== 'boolean') {
      problems.push(`${where}: expected true or false, got ${JSON.stringify(v)}`);
      continue;
    }
    if (spec.type === 'string' && typeof v !== 'string') {
      problems.push(`${where}: expected a string, got ${JSON.stringify(v)}`);
      continue;
    }
    if (spec.minimum !== undefined && v < spec.minimum) {
      problems.push(`${where}: ${v} is below the minimum ${spec.minimum}`);
    }
    if (spec.maximum !== undefined && v > spec.maximum) {
      problems.push(`${where}: ${v} is above the maximum ${spec.maximum}`);
    }
    if (spec.maxLength !== undefined && String(v).length > spec.maxLength) {
      problems.push(`${where}: longer than ${spec.maxLength} characters`);
    }
  }

  return { resolved, problems };
}

const read = (p, label) => {
  try {
    return readFileSync(p, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    process.stderr.write(`validate-intake: cannot read ${label} ${p}: ${err.message}\n`);
    process.exit(2);
  }
};

const schemaText = read(schemaPath, 'schema');
if (schemaText == null) {
  process.stderr.write(`validate-intake: schema missing at ${schemaPath}\n`);
  process.exit(2);
}
const schema = JSON.parse(schemaText);

const intakeText = read(intakePath, 'intake');
const parsed = intakeText == null ? { values: {}, problems: [] } : parseFlatYaml(intakeText);
const { resolved, problems } = validate(parsed.values, schema);
const all = [...parsed.problems, ...problems];

if (asJson) {
  process.stdout.write(`${JSON.stringify({ ok: all.length === 0, problems: all, resolved }, null, 2)}\n`);
} else {
  process.stdout.write(intakeText == null
    ? `validate-intake: ${intakePath} absent — every field takes its schema default\n`
    : `validate-intake: ${intakePath}\n`);
  for (const [k, v] of Object.entries(resolved)) {
    process.stdout.write(`  ${k.padEnd(26)} ${JSON.stringify(v)}\n`);
  }
  if (all.length) {
    process.stdout.write(`validate-intake: FAIL — ${all.length} problem(s)\n`);
    for (const p of all) process.stdout.write(`  ${p}\n`);
  } else {
    process.stdout.write('validate-intake: valid\n');
  }
}

process.exit(all.length === 0 ? 0 : 1);
