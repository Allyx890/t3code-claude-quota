// Runs while T3 is stopped. Drops the settings key of the retired v1 build and
// writes claude-quota.json from the template the first time; an existing
// claude-quota.json is the user's and is left as is.
//
// usage: node prepare-settings.mjs <settings.json> <claude-quota.json> <template.json>
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const [settingsPath, quotaPath, templatePath] = process.argv.slice(2);
if (existsSync(settingsPath)) {
  const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  if ('claudeQuotaAutomation' in settings) {
    delete settings.claudeQuotaAutomation;
    writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, 'utf8');
    console.log('removed retired claudeQuotaAutomation from settings.json');
  }
}
if (existsSync(quotaPath)) console.log('claude-quota.json kept');
else {
  JSON.parse(readFileSync(templatePath, 'utf8'));
  copyFileSync(templatePath, quotaPath);
  console.log('claude-quota.json created');
}
