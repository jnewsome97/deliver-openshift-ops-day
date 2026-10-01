/*
 * Keep the normal Showroom Console tab embedded while allowing browsers that
 * partition third-party storage to grant the Console origin access on the
 * user's existing tab click.  This is intentionally progressive: browsers
 * without requestStorageAccessFor() keep the original iframe behavior.
 */
(function () {
  'use strict';

  var consoleOrigin = '__CONSOLE_ORIGIN__';
  var consoleFrame;

  function findConsoleFrame() {
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i += 1) {
      try {
        if (new URL(frames[i].src, window.location.href).origin === consoleOrigin) {
          return frames[i];
        }
      } catch (_) {
        // Ignore incomplete iframe URLs while the Showroom shell is mounting.
      }
    }
    return null;
  }

  function prepareConsoleFrame() {
    consoleFrame = findConsoleFrame();
    if (consoleFrame) {
      consoleFrame.setAttribute(
        'allow',
        'clipboard-write; clipboard-read; storage-access'
      );
    }
  }

  function requestConsoleStorageAccess() {
    prepareConsoleFrame();
    if (typeof document.requestStorageAccessFor !== 'function') {
      return;
    }

    document.requestStorageAccessFor(consoleOrigin).then(function () {
      // Reload only after permission is granted so the OAuth request retries
      // with the newly available storage context.
      if (consoleFrame) {
        consoleFrame.src = consoleFrame.src;
      }
    }).catch(function () {
      // The normal iframe flow remains available if the browser denies it.
    });
  }

  document.addEventListener('click', function (event) {
    var tab = event.target.closest && event.target.closest('[role="tab"]');
    if (tab && tab.textContent.trim().indexOf('OCP Console') === 0) {
      requestConsoleStorageAccess();
    }
  }, true);

  new MutationObserver(prepareConsoleFrame).observe(document.documentElement, {
    childList: true,
    subtree: true
  });
  prepareConsoleFrame();
}());
