#!/usr/bin/env bash
#
# One-time setup so the drill can run unattended.
#
# Creates a federated Entra application, adds it as an application user in both
# Dataverse environments, gives it a security role, and configures this
# repository. Re-runnable: everything it creates is looked up first.
#
# Needs: az, gh. Not jq -- both tools parse JSON themselves.
set -euo pipefail

DEV_URL=""
TARGET_URL=""
REPO=""
ENVIRONMENT="lab"
APP_NAME="the-import-said-success-orchestrator"
# Dataverse, the same application id in every tenant.
DV_APP="00000007-0000-0000-c000-000000000000"

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap.sh --dev <url> --target <url> [--repo owner/name] [--environment name]

  --dev          Dataverse URL of the dev environment, e.g. https://x.crm.dynamics.com
  --target       Dataverse URL of the target environment
  --repo         GitHub repository as owner/name. Defaults to this checkout's origin.
  --environment  GitHub environment named in the OIDC subject. Default: lab
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dev) DEV_URL="${2:-}"; shift 2 ;;
    --target) TARGET_URL="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$DEV_URL" ] || [ -z "$TARGET_URL" ]; then
  echo "--dev and --target are both required." >&2
  usage
  exit 2
fi

DEV_URL="${DEV_URL%/}"
TARGET_URL="${TARGET_URL%/}"

say() { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# ------------------------------------------------------------------ preflight

say "Checking prerequisites"
for tool in az gh; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not signed in to az. Run: az login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not signed in to gh. Run: gh auth login" >&2; exit 1; }

TENANT_ID=$(az account show --query tenantId -o tsv)
note "tenant ${TENANT_ID}"

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] || { echo "Could not work out the repository. Pass --repo owner/name." >&2; exit 1; }
fi

# The IMMUTABLE subject form, built from GitHub's numeric ids. The portable
# repo:OWNER/REPO form is what the documentation shows and it does not work:
# GitHub presents repo:OWNER@OWNERID/REPO@REPOID and Entra matches the subject
# as an exact string. A sibling lab in this series died on AADSTS700213 proving it.
OWNER_ID=$(gh api "repos/${REPO}" -q .owner.id)
REPO_ID=$(gh api "repos/${REPO}" -q .id)
SUBJECT="repo:${REPO%%/*}@${OWNER_ID}/${REPO#*/}@${REPO_ID}:environment:${ENVIRONMENT}"
note "repository ${REPO}"
note "OIDC subject ${SUBJECT}"

# ------------------------------------------------------------- the identity

say "Creating the orchestrator application"
APP_ID=$(az ad app list --filter "displayName eq '${APP_NAME}'" --query '[0].appId' -o tsv 2>/dev/null || true)
if [ -n "$APP_ID" ] && [ "$APP_ID" != "None" ]; then
  note "reusing ${APP_ID}"
else
  APP_ID=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)
  note "created ${APP_ID}"
fi

SP_OBJECT_ID=$(az ad sp list --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv 2>/dev/null || true)
if [ -z "$SP_OBJECT_ID" ] || [ "$SP_OBJECT_ID" = "None" ]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  note "created service principal ${SP_OBJECT_ID}"
fi

say "Adding the federated credential"
EXISTING=$(az ad app federated-credential list --id "$APP_ID" \
  --query "[?name=='github-actions'].subject | [0]" -o tsv 2>/dev/null || true)
if [ "$EXISTING" = "$SUBJECT" ]; then
  note "already trusts the right subject"
else
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    note "replacing a credential that trusted '${EXISTING}'"
    az ad app federated-credential delete --id "$APP_ID" --federated-credential-id github-actions
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-actions\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
  note "credential set"
fi

# Delegated permission to Dataverse, so the principal can be an application
# user. Without this the systemusers POST below is accepted and the token it
# later asks for is refused, which surfaces as a 401 from Dataverse rather than
# anything pointing at a missing permission.
say "Granting Dataverse access to the application"
az ad app permission add --id "$APP_ID" --api "$DV_APP" \
  --api-permissions "78ce3f0f-a1ce-49c2-8cde-64b5c0896db4=Scope" >/dev/null 2>&1 || true
if az ad app permission admin-consent --id "$APP_ID" >/dev/null 2>&1; then
  note "admin consent granted"
else
  note "WARNING: admin consent refused. Grant it in the Entra portal, or the drill gets 401 from Dataverse."
fi

# --------------------------------------------------- application users

dv() {
  # dv <url> <method> <path> [body]
  local url="$1" method="$2" path="$3" body="${4:-}"
  local token

  # OData filters contain spaces -- applicationid eq <guid>, name eq 'System
  # Administrator' -- and an unencoded space in a URL is rejected outright by
  # curl on Windows with "Malformed input to a URL function", which reads like a
  # problem with the address rather than with one character in the query.
  # Encoded here rather than at each call site so a new query cannot reintroduce
  # it.
  path="${path// /%20}"
  token=$(az account get-access-token --resource "${url}/" --query accessToken -o tsv)
  if [ -n "$body" ]; then
    curl -sS -X "$method" "${url}/api/data/v9.2/${path}" \
      -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      -H 'OData-MaxVersion: 4.0' -H 'OData-Version: 4.0' -H 'Accept: application/json' \
      --data "$body"
  else
    curl -sS -X "$method" "${url}/api/data/v9.2/${path}" \
      -H "Authorization: Bearer ${token}" \
      -H 'OData-MaxVersion: 4.0' -H 'OData-Version: 4.0' -H 'Accept: application/json'
  fi
}

for url in "$DEV_URL" "$TARGET_URL"; do
  say "Adding the application user in ${url}"

  existing=$(dv "$url" GET "systemusers?\$select=systemuserid&\$filter=applicationid eq ${APP_ID}" \
    | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d).value||[];console.log(v.length?v[0].systemuserid:'');}catch(e){console.log('');}})")

  if [ -n "$existing" ]; then
    note "already an application user (${existing})"
    user_id="$existing"
  else
    # Single-quoted on purpose: $select and $filter are OData query syntax, not
    # shell variables, and letting the shell expand them would send an empty
    # query string that returns every business unit.
    # shellcheck disable=SC2016
    bu=$(dv "$url" GET 'businessunits?$select=businessunitid&$filter=parentbusinessunitid eq null' \
      | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{console.log((JSON.parse(d).value||[])[0].businessunitid);}catch(e){console.log('');}})")
    [ -n "$bu" ] || { echo "Could not find the root business unit in ${url}." >&2; exit 1; }

    created=$(dv "$url" POST 'systemusers' "{
      \"applicationid\": \"${APP_ID}\",
      \"businessunitid@odata.bind\": \"/businessunits(${bu})\",
      \"firstname\": \"Layer\",
      \"lastname\": \"Drill\"
    }")
    user_id=$(echo "$created" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);console.log(j.systemuserid||'');}catch(e){console.log('');}})")
    if [ -z "$user_id" ]; then
      # Re-read rather than trust the create response, which returns no body on
      # some configurations.
      user_id=$(dv "$url" GET "systemusers?\$select=systemuserid&\$filter=applicationid eq ${APP_ID}" \
        | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d).value||[];console.log(v.length?v[0].systemuserid:'');}catch(e){console.log('');}})")
    fi
    [ -n "$user_id" ] || { echo "Could not create the application user in ${url}. Response: ${created}" >&2; exit 1; }
    note "created application user ${user_id}"
  fi

  # System Administrator, and not for convenience.
  #
  # The drill imports MANAGED solutions and deletes them from the target.
  # System Customizer can import, but it cannot delete a managed solution, and
  # the drill has to reset the target between passes or the second pass
  # inherits the first one's state and a guard passes for the wrong reason.
  role=$(dv "$url" GET "roles?\$select=roleid&\$filter=name eq 'System Administrator'" \
    | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d).value||[];console.log(v.length?v[0].roleid:'');}catch(e){console.log('');}})")
  [ -n "$role" ] || { echo "Could not find the System Administrator role in ${url}." >&2; exit 1; }

  if dv "$url" POST "systemusers(${user_id})/systemuserroles_association/\$ref" \
      "{\"@odata.id\": \"${url}/api/data/v9.2/roles(${role})\"}" >/dev/null 2>&1; then
    note "System Administrator assigned"
  else
    note "role assignment was refused, probably already present"
  fi
done

# ----------------------------------------------------- github configuration

say "Configuring the repository"

# A newly created repository refuses its first Actions writes with 403, and
# secrets settle later than variables. Retried generously rather than treated
# as a permission problem, which is what the message claims.
gh_write() {
  local what="$1"; shift
  local delay
  for delay in 5 10 20 30 0; do
    if "$@" >/dev/null 2>&1; then note "set ${what}"; return 0; fi
    [ "$delay" -gt 0 ] && { note "setting ${what} was refused, retrying in ${delay}s"; sleep "$delay"; }
  done
  echo "   could not set ${what}; the error follows:" >&2
  "$@" >&2 2>&1 || true
  return 1
}

gh_write "variable DATAVERSE_DEV_URL" gh variable set DATAVERSE_DEV_URL --repo "$REPO" --body "$DEV_URL"
gh_write "variable DATAVERSE_TARGET_URL" gh variable set DATAVERSE_TARGET_URL --repo "$REPO" --body "$TARGET_URL"
# Secrets rather than variables: neither is a credential on its own, but GitHub
# masks secrets in workflow logs and does not mask variables, and the tenant id
# identifies the directory these labs run in.
gh_write "secret AZURE_CLIENT_ID" gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh_write "secret AZURE_TENANT_ID" gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"

if gh api "repos/${REPO}/environments/${ENVIRONMENT}" >/dev/null 2>&1; then
  note "environment '${ENVIRONMENT}' already exists"
else
  gh_write "environment ${ENVIRONMENT}" gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}"
fi

say "Done"
cat <<EOF

  Application   ${APP_NAME}
  Client id     ${APP_ID}
  Tenant id     ${TENANT_ID}
  Subject       ${SUBJECT}
  Dev           ${DEV_URL}
  Target        ${TARGET_URL}

  Entra federated credentials take about three minutes to propagate. Then:

    gh workflow run drill.yml --repo ${REPO}
EOF
