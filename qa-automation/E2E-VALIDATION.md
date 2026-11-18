# Full automated e2e validation

The merge gate is one complete successful invocation of the actual Showroom
`/stream/qa/e2e` endpoint against the exact checked-out QA commit, plus cleanup
verification. Unit tests do not substitute for that run. Keep release/catalog
PRs unmerged while any required automated check fails.

## Truthful prerequisites

A cluster on the latest release may correctly offer no updates. The OLS test
requires successful CVO update retrieval. It reports the unavailable update-UI
exercise explicitly rather than changing ClusterVersion or adding a fake feed.
Set `qa_require_cluster_update_demo: true` to require an offered update; that
strict mode still fails if no update exists. Module 13 documents this condition.

Do not assume that CVO or alerts created an AgenticRun. The suite performs a real
MaaS request and creates its own uniquely named analysis-only AgenticRun. It must
finish with a successful analysis result; mere CR existence is insufficient.
The CR has no execution/verification/tools and uses immutable Minimal output.
The suite verifies its ownership/UID and approves only its Analysis stage in
the matching controller-owned AgenticRunApproval. It never changes global
ApprovalPolicy or approves execution/remediation. Cleanup checks ownership and deletes only its run,
without force-clearing finalizers. Shared alerts-adapter settings and existing
learner/CVO/alert-origin runs are not modified or deleted.

## Isolation and convergence

- Namespace deletion waits query the Namespace API. Authentication, network or
  CLI errors cannot be mistaken for a successful NotFound response.
- Safe API requests have finite retry budgets; existing condition checks remain
  required. Polling includes request success so stale data cannot hide errors.
- ACM uses `qa-e2e-acm-policy`, including its required binding name `default`.
  It cannot create/delete `policies/default`. Policy namespace deletion finishes
  before its enforced QA namespace is removed.
- Vault uses a private `qa-e2e-kubernetes` auth mount rather than rewriting the
  learner's `auth/kubernetes` backend. QA secrets/policies/roles have QA names.
  ESO is shared infrastructure: its test-created ExternalSecret is removed and
  finalizer clearance required before dependent test objects are removed; ESO
  itself is not uninstalled. The suite may install ESO when absent.
- Observability must observe an actual Firing metric for its own alert; the
  query is not ignored on failure and does not pass by matching an error string.
- Preserve all original enabled-module includes and module-selection gates.
  Do not disable modules, suppress failures or modify production update sources
  merely to obtain a green recap.

New retry controls: `qa_api_retries` (default 12), `qa_poll_delay` (default 5s),
`qa_readiness_retries` (defaults retain/extend short waits to ~5min),
`qa_namespace_delete_retries` (default 60), and the dedicated OLS deployment and
analysis polling controls. Budgets are per stage, cumulative, and exclude
request duration.

Helm bootstrap pins v3.16.4 and its official SHA-256. Download uses a finite
`qa_download_retries` budget (default 6 retries after the initial attempt),
`qa_download_timeout` socket timeout (default 60s), and verified local extraction.
Helm repository operations also retry without ignoring permanent failures and
use private QA config/cache paths. If bootstrap fails before ESO APIs exist,
cleanup confirms CRD absence before skipping only custom-resource deletion;
API/auth failures remain fatal. When ESO exists, ExternalSecret finalizers must
clear before provider credentials are removed. ESO installation and secret
sync are still required assertions, never skipped to hide a bootstrap failure.

## Coverage boundaries

The final play output reports known boundaries: LDAP/OIDC OAuth switching,
RHACS-side detection, Loki/Tempo installation, VPA/load-driven scaling, and
interactive approval/execution/UI flows are not claimed automated by this
suite. A green automated run does not prove every interactive learner exercise.
Any claim of complete workshop acceptance must include those separate checks.
