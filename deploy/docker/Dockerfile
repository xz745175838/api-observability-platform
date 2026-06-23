# Build one service image: docker build --build-arg SERVICE=collector -t vsan-collector:latest .
# 定义一个构建参数 SERVICE，默认值为 collector。
# 通过构建参数 SERVICE 控制要编译的目标，以支持多服务场景（如 collector、processor、query-api）
ARG SERVICE=collector
# 只需指定 SERVICE=processor 或 SERVICE=query-api 即可构建对应服务镜像
# 例如：
#   docker build --build-arg SERVICE=processor -t vsan-processor:latest .
#   docker build --build-arg SERVICE=query-api -t vsan-query-api:latest .

# 使用 Go 1.22 Alpine 版本作为基础镜像，用于编译二进制文件
# 这是一个用于构建 Go 服务应用（如 collector、processor、query-api）的多阶段构建镜像，首阶段以 Go 1.22 Alpine 作为编译环境。

FROM docker.m.daocloud.io/library/golang:1.22-alpine AS build

# 声明 SERVICE 构建参数，指定要编译的服务
ARG SERVICE

# 设置工作目录为 /src
WORKDIR /src

# 安装 git 和 ca-certificates（阿尔派恩包管理器），用于拉取依赖和 HTTPS 支持
RUN apk add --no-cache git ca-certificates

# 复制 go.mod / go.sum，便于依赖缓存与校验
COPY go.mod go.sum ./

# 下载项目所有的 Go 依赖
RUN go mod download

# 复制当前项目目录下所有文件到镜像的工作目录中
COPY . .

# 编译服务对应的 Go 程序，输出到 /out/app
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/app ./cmd/${SERVICE}

# 以 Distroless 最小化镜像为基础，用于生产环境的最终镜像
# 这不是一个完整的操作系统镜像，它是一个极简的“distroless”基础镜像，仅包含运行 Go 程序所必需的最少文件和运行库，不包含 shell、包管理器等操作系统工具。
FROM gcr.io/distroless/static-debian12:nonroot

# 从上一步构建中复制编译好的二进制文件到最终镜像的 /app 目录
# 不能直接 -o /app 是因为多阶段构建时，build 阶段的文件系统与最终生产镜像（distroless 或 scratch 等）完全隔离，无法在 build 阶段直接把二进制写到最终镜像里。
# 只能先在 build 阶段的镜像（如 golang:alpine）内任意写出产物，再在生产镜像阶段用 COPY --from=build 拷贝进来。
COPY --from=build /out/app /app

# 以非 root 用户运行，提升镜像安全性
USER nonroot:nonroot

# 设置容器启动时的命令，运行二进制文件
ENTRYPOINT ["/app"]  