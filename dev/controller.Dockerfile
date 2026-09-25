# A local controller, for running the drill on a machine without PowerShell 7.
#
# Not used by CI -- the GitHub runner already has both pwsh and the Azure CLI,
# so the workflow runs the drill directly.
#
# The drill needs PowerShell 7 rather than Windows PowerShell 5.1, and not as a
# style preference: it reads HTTP status codes off non-2xx responses with
# Invoke-RestMethod -SkipHttpErrorCheck -StatusCodeVariable, which 5.1 does not
# have. "The import returned success" is a thing this lab has to record rather
# than infer from an absence of exceptions, so that matters.
#
# Run it with the Azure CLI token cache mounted, so it authenticates as you
# rather than holding a credential of its own:
#
#   docker build -f dev/controller.Dockerfile -t layer-controller dev
#   docker run --rm -v "$HOME/.azure:/root/.azure" -v "$PWD:/lab" -w /lab \
#     layer-controller pwsh -File scripts/Invoke-LayerDrill.ps1 \
#       -DevUrl https://yourdev.crm.dynamics.com \
#       -TargetUrl https://yourtarget.crm.dynamics.com
#
# That mount gives the container your refresh tokens for as long as it runs.
# It is your machine and your container, but it is worth knowing rather than
# discovering.

FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# A virtualenv because Ubuntu 24.04 marks its system Python externally managed
# and pip refuses to write into it. --break-system-packages also works and is
# the wrong habit to leave in a file somebody might copy.
ENV VIRTUAL_ENV=/opt/azcli
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir azure-cli

CMD ["pwsh"]
