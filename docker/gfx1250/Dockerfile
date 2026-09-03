FROM ubuntu:24.04

# 設定環境變數：防止 apt 安裝時跳出互動式選擇視窗，並預設 PIP 不警告
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1    \
    PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH

# 核心系統套件與開發工具安裝
RUN apt-get update                                              && \
    apt-get install -y --no-install-recommends --fix-missing       \
    ca-certificates curl wget sudo git tig vim tree tmux net-tools \
    build-essential cmake ninja-build g++ gfortran gh wine         \
    libnuma-dev m4 libatomic1 libgomp1 libdw-dev libgmock-dev      \
    liblapack-dev libblas-dev libmsgpack-dev libgtest-dev          \
    python3 python3-dev python3-pip python3-packaging python3-yaml \
    python3-msgpack python3.12-venv openssh-client
RUN pip install --upgrade --ignore-installed pip                && \
    pip install --no-cache-dir --ignore-installed                  \
    invoke "joblib>=1.4.0" msgpack orjson packaging plotly         \
    plotext python-dateutil pytz PyYAML simplejson sqlalchemy      \
    textual textual-fspicker textual_plotext typing_extensions     \
    ujson yappi tox numpy hip-python nanobind einops flask         \
    scikit-build-core importlib_metadata

# therock 編譯環境 https://rocm.nightlies.amd.com/tarball-multi-arch/
# THEROCK_VER / THEROCK_TAR 由 env.sh 依 TAG 推導後傳入，避免與腳本的 TAG 漂移。
ARG THEROCK_VER='rocm7.15.0a20260712'
ARG THEROCK_TAR='therock-dist-linux-gfx125X-dcgpu-7.15.0a20260712.tar.gz'
ARG THEROCK_URL='https://rocm.nightlies.amd.com/tarball-multi-arch'
RUN mkdir -p /opt/$THEROCK_VER                              && \
    wget -O /tmp/therock.tar.gz "$THEROCK_URL/$THEROCK_TAR" && \
    tar -xf /tmp/therock.tar.gz -C /opt/$THEROCK_VER/       && \
    rm /tmp/therock.tar.gz                                  && \
    ln -s /opt/$THEROCK_VER /opt/rocm

RUN ln -sf librocprof-trace-decoder.so.0.2 /opt/$THEROCK_VER/lib/librocprof-trace-decoder.so

# /opt/rocm/lib 沒被 ldconfig 收錄，自己 compile 的 binary 會找不到 libamdhip64.so.7。
# 用 symlink 路徑而非寫死版本號，換 THEROCK_VER 時才不會失效。
RUN echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf && ldconfig

# rocdtif 模擬環境 CSIM+AM+FFM，只有 MODE=sim 會裝。
# hw build 不傳 --secret，secret 預設 required=false，分支不執行也就不會取用。
ARG WITH_ROCDTIF=0
ARG ROCDTIF_TAR='rocdtif-7.15-am+ffmlite-mi400-r8.03.tar.gz'
ARG ROCDTIF_URL='https://atlartifactory.amd.com:8443/artifactory/SW-ROCDTIF-MI-DEV-LOCAL/Packages/AM+FFM-LITE/Release'
RUN --mount=type=secret,id=artitoken                                        \
    if [ "$WITH_ROCDTIF" = "1" ]; then                                      \
        wget --header="Authorization: Bearer $(cat /run/secrets/artitoken)" \
             -O /tmp/rocdtif.tar.gz "$ROCDTIF_URL/$ROCDTIF_TAR"          && \
        tar xf /tmp/rocdtif.tar.gz -C /opt                               && \
        rm /tmp/rocdtif.tar.gz                                           && \
        ln -s /opt/rocdtif-* /opt/rocdtif;                                  \
    fi

RUN rm -rf /var/lib/apt/lists/*
# ===========================================================
# 參數定義 (可在 docker run 加上 --user $(id -u):$(id -g))
# ===========================================================
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000
# hw 模式下 host /dev/kfd 所屬的 GID (通常是 render group)。空字串代表不掛裝置(sim 模式)。
# 補上這筆 /etc/group 紀錄純粹是讓 `groups`/`id` 查得到名字，不影響 --group-add 本身的裝置權限。
ARG RENDER_GID=

RUN groupadd -g ${USER_GID} -f ${USERNAME} && \
    if [ -n "${RENDER_GID}" ] && ! getent group ${RENDER_GID} >/dev/null; then \
        groupadd -g ${RENDER_GID} render; \
    fi && \
    useradd -m -u ${USER_UID} -g ${USER_GID} -o -s /bin/bash ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers            && \
    echo "set nu" > /root/.vimrc

USER ${USERNAME}
WORKDIR /home/${USERNAME}
RUN echo "set nu" > ~/.vimrc
