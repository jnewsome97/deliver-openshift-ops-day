'use strict'

// After Antora publishes the site, symlink support/ from the repo root into the
// output dir so the showroom content server serves it at /support/...
// This lets ui-config's support_base_url point to the live showroom URL instead
// of falling back to GitHub every time.
module.exports.register = function ({ on }) {
  on('sitePublished', ({ playbook }) => {
    const { symlinkSync, existsSync } = require('fs')
    const { join, resolve } = require('path')
    const outputDir = resolve(playbook.output.dir)
    const repoDir = resolve(playbook.dir)
    const src = join(repoDir, 'support')
    const dst = join(outputDir, 'support')
    if (existsSync(src) && !existsSync(dst)) {
      symlinkSync(src, dst)
    }
  })
}
