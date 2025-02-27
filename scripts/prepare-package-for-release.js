/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 */

'use strict';

/**
 * This script prepares a release package to be pushed to npm
 * It is run by CircleCI on a push to a release branch
 * It will:
 *    * It updates the version in json/gradle files and makes sure they are consistent between each other (set-rn-version)
 *    * Updates podfile for RNTester
 *    * Commits changes and tags with the next version based off of last version tag.
 *      This in turn will trigger another CircleCI job to publish to npm
 */
const {echo, exec, exit} = require('shelljs');
const yargs = require('yargs');
const {
  isReleaseBranch,
  isTaggedLatest,
  getPublishVersion,
  getPublishTag,
} = require('./version-utils');

const argv = yargs.option('r', {
  alias: 'remote',
  default: 'origin',
}).argv;

const currentCommit = process.env.CIRCLE_SHA1;
const branch = process.env.CIRCLE_BRANCH;
const remote = argv.remote;

const tag = getPublishTag();
if (tag == null) {
  console.log(
    'No publish tag set. Not publishing this release.\nCircleCI cannot filter workflows on both branch and tag so we do this check in prepare-package-for-release',
  );
  exit(0);
}

if (!isReleaseBranch(branch)) {
  console.error(`This needs to be on a release branch. On branch: ${branch}`);
  exit(1);
}

// Get the version we're publishing from the publish tag
// Tag of the form `publish-v{versionStr}`
const versionInfo = getPublishVersion(tag);
if (versionInfo == null) {
  console.error(
    `Invalid tag provided: ${tag}, needs to be of form 'publish-v{major}.{minor}.{patch}'`,
  );
  exit(1);
}

// Clean up tag now that we're publishing the release.
exec(`git tag -d ${tag}`);
exec(`git push ${remote} :${tag}`);

const {version} = versionInfo;

if (exec(`node scripts/set-rn-version.js --to-version ${version}`).code) {
  echo(`Failed to set React Native version to ${version}`);
  exit(1);
}

// Release builds should commit the version bumps, and create tags.
echo('Updating RNTester Podfile.lock...');
if (exec('source scripts/update_podfile_lock.sh && update_pods').code) {
  echo('Failed to update RNTester Podfile.lock.');
  echo('Fix the issue, revert and try again.');
  exit(1);
}

// Make commit [0.21.0-rc] Bump version numbers
if (exec(`git commit -a -m "[${version}] Bump version numbers"`).code) {
  echo('failed to commit');
  exit(1);
}

// Add tag v0.21.0-rc.1
if (exec(`git tag -a v${version} -m "v${version}"`).code) {
  echo(
    `failed to tag the commit with v${version}, are you sure this release wasn't made earlier?`,
  );
  echo('You may want to rollback the last commit');
  echo('git reset --hard HEAD~1');
  exit(1);
}

// See if `latest` was set on the commit that triggered this script
// If yes, move the tag to commit we just made
// This tag will also update npm release as `latest`
const isLatest = isTaggedLatest(currentCommit);
if (isLatest) {
  exec('git tag -d latest');
  exec(`git push ${remote} :latest`);

  // This will be pushed with the `--follow-tags`
  exec('git tag -a latest -m "latest"');
}

exec(`git push ${remote} ${branch} --follow-tags`);

exit(0);
