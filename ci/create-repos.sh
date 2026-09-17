#!/bin/bash
set -euo pipefail

# Organize built RPMs into per-distribution RPM repositories, generate
# repository metadata with createrepo_c and, optionally, GPG-sign the RPMs and
# the repository metadata.
#
# Usage:
#   create-repos.sh <artifacts-dir> <output-dir> <repository> [base-url]
#
#   artifacts-dir  Directory that contains the downloaded GitHub Actions
#                  artifacts (RPMs may live in nested subdirectories).
#   output-dir     Directory where the repo tree, .repo files and an index
#                  page are written. Deploy this directory to GitHub Pages.
#   repository     GitHub repository in "owner/name" form. Used to compute the
#                  default base URL for the generated .repo files.
#   base-url       Optional base URL override. Defaults to the GitHub Pages URL
#                  derived from <repository>.
#
# Signing is enabled when the following environment variables are present:
#
#   GPG_PRIVATE_KEY  ASCII-armored private key to import and sign with.
#   GPG_PASSPHRASE   Optional passphrase for the key (empty if unprotected).
#   GPG_KEY_ID       Optional key id/email; auto-detected from the key if unset.
#
# When signing is enabled the public key is exported to
# <output-dir>/RPM-GPG-KEY-displaylink and the generated .repo files set
# gpgcheck/repo_gpgcheck accordingly.

ARTIFACTS_DIR="${1:?usage: create-repos.sh <artifacts-dir> <output-dir> <repository> [base-url]}"
OUTPUT_DIR="${2:?}"
REPOSITORY="${3:?}"
OWNER="${REPOSITORY%%/*}"
REPO_NAME="${REPOSITORY#*/}"
BASE_URL="${4:-https://${OWNER}.github.io/${REPO_NAME}/}"

if ! command -v createrepo_c >/dev/null 2>&1; then
  echo "ERROR: createrepo_c is required but was not found in PATH" >&2
  exit 1
fi

SIGNING=0
if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
  SIGNING=1
  for tool in gpg rpmsign; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "ERROR: ${tool} is required for signing but was not found in PATH" >&2
      exit 1
    fi
  done
fi

REPOS_ROOT="${OUTPUT_DIR}/repos"
mkdir -p "${REPOS_ROOT}"

distro_name() {
  local base
  base="$(basename "$1")"
  case "${base}" in
    fedora-*)        echo fedora ;;
    centos-stream-*) echo centos-stream ;;
    rocky-*)         echo rocky ;;
    almalinux-*)     echo almalinux ;;
    *)               return 1 ;;
  esac
}

distro_version() {
  local base
  base="$(basename "$1")"
  case "${base}" in
    fedora-*)        sed -n 's/^fedora-\([0-9]*\|rawhide\)[-.].*/\1/p' <<<"${base}" ;;
    centos-stream-*) sed -n 's/^centos-stream-\(stream[0-9]*\)[-.].*/\1/p' <<<"${base}" ;;
    rocky-*)         sed -n 's/^rocky-\([0-9]*\)[-.].*/\1/p' <<<"${base}" ;;
    almalinux-*)     sed -n 's/^almalinux-\([0-9]*\)[-.].*/\1/p' <<<"${base}" ;;
    *)               return 1 ;;
  esac
}

# Collect all RPMs and place them in their per-distro repo directory.
declare -A REPOS
while IFS= read -r -d '' rpm; do
  os="$(distro_name "$rpm")" || { echo "WARNING: cannot classify ${rpm}, skipping" >&2; continue; }
  version="$(distro_version "$rpm")"
  dir="${os}/${version}"
  mkdir -p "${REPOS_ROOT}/${dir}"
  cp -n "$rpm" "${REPOS_ROOT}/${dir}/"
  REPOS["${dir}"]=1
done < <(find "${ARTIFACTS_DIR}" -type f -name '*.rpm' -print0)

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "ERROR: no RPMs found under ${ARTIFACTS_DIR}" >&2
  exit 1
fi

# Import the signing key and sign every RPM in place before generating
# repository metadata (signing changes the RPM, which changes its checksum).
KEY_ID=""
if [ "${SIGNING}" -eq 1 ]; then
  echo "Importing GPG signing key ..."
  gpg --batch --import <<< "${GPG_PRIVATE_KEY}"

  KEY_ID="${GPG_KEY_ID:-}"
  if [ -z "${KEY_ID}" ]; then
    KEY_ID="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10; exit}')"
  fi
  if [ -z "${KEY_ID}" ]; then
    echo "ERROR: unable to determine the GPG key id" >&2
    exit 1
  fi

  cat > "${HOME}/.rpmmacros" <<EOF
%_gpg_name ${KEY_ID}
%_signature gpg
%__gpg $(command -v gpg)
%__gpg_sign_cmd %{__gpg} gpg --batch --pinentry-mode loopback --passphrase-fd 0 --no-armor --digest-algo sha256 -u "%{_gpg_name}" --detach-sign --output %{__signature_filename} %{__plaintext_filename}
EOF

  echo "Signing RPMs ..."
  while IFS= read -r -d '' rpm; do
    rpmsign --addsign "${rpm}" <<< "${GPG_PASSPHRASE:-}"
  done < <(find "${REPOS_ROOT}" -type f -name '*.rpm' -print0)
fi

# Generate repository metadata and sign repomd.xml.
for dir in $(printf '%s\n' "${!REPOS[@]}" | sort); do
  echo "Creating repository metadata for ${dir} ..."
  (cd "${REPOS_ROOT}/${dir}" && createrepo_c --update .)

  if [ "${SIGNING}" -eq 1 ]; then
    (cd "${REPOS_ROOT}/${dir}" && \
      gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
        --local-user "${KEY_ID}" --armor --detach-sign \
        --output repodata/repomd.xml.asc repodata/repomd.xml \
        <<< "${GPG_PASSPHRASE:-}")
  fi
done

# Export the public key so users can import it into RPM.
if [ "${SIGNING}" -eq 1 ]; then
  gpg --batch --armor --export "${KEY_ID}" > "${OUTPUT_DIR}/RPM-GPG-KEY-displaylink"
  echo "Exported ${OUTPUT_DIR}/RPM-GPG-KEY-displaylink"
fi

# Generate a dnf/yum .repo file per distro/version.
for dir in $(printf '%s\n' "${!REPOS[@]}" | sort); do
  os="${dir%%/*}"
  version="${dir#*/}"
  repoid="displaylink-${os}-${version}"
  repo_file="${OUTPUT_DIR}/${os}-${version}.repo"
  {
    echo "[${repoid}]"
    echo "name=DisplayLink driver for ${os} ${version}"
    echo "baseurl=${BASE_URL}repos/${dir}/"
    echo "enabled=1"
    if [ "${SIGNING}" -eq 1 ]; then
      echo "gpgcheck=1"
      echo "repo_gpgcheck=1"
      echo "gpgkey=${BASE_URL}RPM-GPG-KEY-displaylink"
    else
      echo "gpgcheck=0"
    fi
    echo
  } > "${repo_file}"
  echo "Wrote ${repo_file}"
done

# Simple index page linking to every repository and .repo file.
{
  echo '<!doctype html>'
  echo '<html><head><title>displaylink-rpm repositories</title></head><body>'
  echo '<h1>displaylink-rpm repositories</h1>'
  echo '<p>Add a repository to your system by pointing dnf at a <code>baseurl</code>'
  echo 'below, or by adding one of the generated <code>.repo</code> files, e.g.:</p>'
  echo '<pre>dnf config-manager --add-repo '"${BASE_URL}"'fedora-43.repo</pre>'
  if [ "${SIGNING}" -eq 1 ]; then
    echo '<p>Import the signing key first:</p>'
    echo '<pre>sudo rpm --import '"${BASE_URL}"'RPM-GPG-KEY-displaylink</pre>'
  fi
  echo '<ul>'
  for dir in $(printf '%s\n' "${!REPOS[@]}" | sort); do
    echo "<li><a href=\"repos/${dir}/\">${dir}</a></li>"
  done
  echo '</ul>'
  echo '</body></html>'
} > "${OUTPUT_DIR}/index.html"

echo "Repositories written to ${REPOS_ROOT}"
