FROM nvidia/cuda:11.4.3-cudnn8-devel-ubuntu20.04

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="1000"
ARG NB_USER_PWD="Docker!"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND noninteractive

USER root

RUN apt-get update --yes && \
    # - apt-get upgrade is run to patch known vulnerabilities in apt-get packages as
    #   the ubuntu base image is rebuilt too seldom sometimes (less than once a month)
    apt-get upgrade --yes && \
    apt-get install --yes --no-install-recommends  --allow-change-held-packages \
    # - bzip2 is necessary to extract the micromamba executable.
    bzip2 \
    ca-certificates \
    locales \
    sudo \
    openssh-client \
    openssh-server \
    git \
    build-essential \
    vim \
    tmux \
    # - tini is installed as a helpful container entrypoint that reaps zombie
    #   processes and such of the actual executable we want to start, see
    #   https://github.com/krallin/tini#why-tini for details.
    tini \
    wget \
    fonts-liberation \
    # - pandoc is used to convert notebooks to html files
    #   it's not present in aarch64 ubuntu image, so we install it here
    pandoc \
    curl \
    # - run-one - a wrapper script that runs no more
    #   than one unique  instance  of  some  command with a unique set of arguments,
    #   we use `run-one-constantly` to support `RESTARTABLE` option
    run-one \
    libsm6 \
    libxext6 \
    libnccl2 \
    libnccl-dev \
    htop && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

RUN useradd -ms /bin/bash -g root -G sudo -u ${NB_UID} ${NB_USER}
RUN echo "${NB_USER}:${NB_USER_PWD}" | chpasswd

ARG PYTHON_VERSION=3.10

COPY ./initial-condarc "${CONDA_DIR}/.condarc"

WORKDIR /tmp
RUN chown "${NB_USER}" "${CONDA_DIR}"
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
        # Should be simpler, see <https://github.com/mamba-org/mamba/issues/1437>
        arch="64"; \
    fi && \
    wget -qO /tmp/micromamba.tar.bz2 \
        "https://micromamba.snakepit.net/api/micromamba/linux-${arch}/latest" && \
    tar -xvjf /tmp/micromamba.tar.bz2 --strip-components=1 bin/micromamba && \
    rm /tmp/micromamba.tar.bz2 && \
    PYTHON_SPECIFIER="python=${PYTHON_VERSION}" && \
    if [[ "${PYTHON_VERSION}" == "default" ]]; then PYTHON_SPECIFIER="python"; fi && \
    # Install the packages
    ./micromamba install \
        --root-prefix="${CONDA_DIR}" \
        --prefix="${CONDA_DIR}" \
        --yes \
        "${PYTHON_SPECIFIER}" \
        'mamba' \
        'jupyter_core' && \
    rm micromamba && \
    # Pin major.minor version of python
    mamba list python | grep '^python ' | tr -s ' ' | cut -d ' ' -f 1,2 >> "${CONDA_DIR}/conda-meta/pinned" && \
    mamba clean --all -f -y

RUN mamba install --quiet --yes \
    'notebook' \
    'jupyterhub' \
    'jupyterlab' \
    'nb_conda_kernels' \
    'jupyter-server-proxy' \
    'jupyterlab' -c conda-forge && \
    jupyter notebook --generate-config && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter lab clean && \
    pip install --quiet --no-cache-dir jupyterlab-system-monitor jupyterlab-git
EXPOSE 8888

COPY start-notebook.sh start-singleuser.sh /usr/local/bin/
COPY jupyter_server_config.py /etc/jupyter/
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py

HEALTHCHECK  --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -O- --no-verbose --tries=1 --no-check-certificate \
    http${GEN_CERT:+s}://localhost:8888${JUPYTERHUB_SERVICE_PREFIX:-/}api || exit 1

ENTRYPOINT ["tini", "-g", "--"]


COPY jupyter_codeserver_proxy ${HOME}/jupyter_codeserver_proxy
RUN cd ${HOME}/jupyter_codeserver_proxy \
    && python setup.py bdist_wheel  \
    && pip install --quiet --no-cache-dir dist/jupyter_codeserver_proxy-1.0b3-py3-none-any.whl \
    && cd ${HOME} && rm -r jupyter_codeserver_proxy

RUN curl -fsSL https://code-server.dev/install.sh | sh && \
    rm -rf "${HOME}/.cache"

USER ${NB_USER}

WORKDIR ${HOME}

CMD ["sh","-c", "jupyter lab --allow-root --notebook-dir=/home/jovyan --ip=0.0.0.0 --no-browser --port=8888 --NotebookApp.token='' --NotebookApp.password='' --NotebookApp.allow_origin='*' --NotebookApp.base_url=${NB_PREFIX}"]