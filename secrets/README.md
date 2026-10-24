# Local provider keys used by scripts/deploy-app.sh.
#
# Create app.env here (it is gitignored) with one KEY=VALUE per line:
#
#   OPENAI_API_KEY=sk-...
#   MODELARTS_API_BASE=https://<endpoint>/v1
#   MODELARTS_API_KEY=...
#
# The script merges this file into the litellm-secrets Kubernetes Secret on
# every deploy. Never commit the file.
