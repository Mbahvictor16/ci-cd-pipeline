A Node.js web service delivered through a CI/CD pipeline: **GitHub → Jenkins → Docker/DockerHub → Ansible → Kubernetes (Minikube)**.

Built for *Software Engineering and DevOps (MMI330704)*, Coursework 2.

---

## Table of contents

1. [Overview](#1-overview)
2. [Repository layout](#2-repository-layout)
3. [Architecture](#3-architecture)
4. [Application (`server.js`)](#4-application-serverjs)
5. [Container image (`Dockerfile`)](#5-container-image-dockerfile)
6. [CI/CD pipeline (`Jenkinsfile`)](#6-cicd-pipeline-jenkinsfile)
7. [Production server and Kubernetes](#7-production-server-and-kubernetes)
8. [Setup guide](#8-setup-guide)
9. [Usage and verification](#9-usage-and-verification)
10. [Known issues and recommended improvements](#10-known-issues-and-recommended-improvements)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Overview

| Item | Value |
|---|---|
| Application | Plain Node.js HTTP server (no dependencies) |
| Listens on | TCP **8081** |
| Image | `mbahvictor/ci-cd-pipeline:1.0` |
| Source repo | `https://github.com/Mbahvictor16/devops_cw2.git` (branch `main`) |
| CI server | Jenkins on the Build Server (port 8080) |
| Runtime | Kubernetes (Minikube) on the Production Server, configured with Ansible |

A push to `main` triggers Jenkins, which builds the image, smoke-tests it, pushes it to DockerHub and then tells the Production Server to run an Ansible playbook that updates the Kubernetes deployment.

---

## 2. Repository layout

```
devops_cw2/
├── server.js      # Application code
├── Dockerfile     # Image definition
└── Jenkinsfile    # Declarative pipeline
```

Files that live on the **Production Server** (not in this repo as supplied):

```
~/k8s.yml          # Ansible playbook run by Jenkins (deploys/updates the app)
(other playbooks)  # kubectl install, Minikube install/start, etc.
```

---

## 3. Architecture

```
 Developer
    │ git push
    ▼
 GitHub (main) ────────────────┐
                               │ checkout
                               ▼
        ┌──────────── Build Server (EC2, Ubuntu) ────────────┐
        │  Jenkins pipeline                                  │
        │   1. Checkout                                      │
        │   2. docker build                                  │
        │   3. docker run + smoke test                       │
        │   4. docker login / push ──────────▶ DockerHub     │
        │   5. ssh → ansible-playbook ───┐                   │
        └────────────────────────────────┼───────────────────┘
                                         ▼
        ┌────────── Production Server (EC2, Ubuntu) ─────────┐
        │  Ansible → kubectl → Minikube                      │
        │   Deployment (replicas, RollingUpdate)             │
        │   Service (NodePort) ◀── curl $(minikube ip):port  │
        │   Pods pull image from DockerHub                   │
        └────────────────────────────────────────────────────┘
```

| Server | Spec | Software |
|---|---|---|
| Build Server | EC2 t2.large, Ubuntu, 12 GB, port 8080 open | Git, Docker, Jenkins |
| Production Server | EC2 t2.large, Ubuntu, 12 GB | Ansible, kubectl, Minikube (+ Docker driver) |

---

## 4. Application (`server.js`)

A minimal HTTP server that returns a plain-text response identifying the pod that served it, so load balancing and rolling updates are visible.

```js
var http = require('http');
var requests=0;
var podname= process.env.HOSTNAME;
var startTime;
var host;

var handleRequest = function(request, response) {
  response.setHeader('Content-Type', 'text/plain');
  response.writeHead(200);
  response.write("DevOps Coursework 2! | Running on: ");
  response.write(host);
  response.end(" | v=1\n");
  console.log("Running On:" ,host, "| Total Requests:", ++requests,"| App Uptime:", (new Date() - startTime)/1000 , "seconds", "| Log Time:",new Date());}

var www = http.createServer(handleRequest);
www.listen(8081,function () {
    startTime = new Date();;
    host = process.env.HOSTNAME;
    console.log ("Started At:",startTime, "| Running On: " ,host, "\n" );
});
```

### Behaviour

| Aspect | Detail |
|---|---|
| Endpoint | Any path/method on port `8081` returns `200 text/plain` |
| Response body | `DevOps Coursework 2! \| Running on: <HOSTNAME> \| v=<n>` |
| `HOSTNAME` | In Kubernetes this is the **pod name**, so repeated requests show which replica answered |
| Version marker | The `v=` value in `response.end(...)` – increment it to prove a new release was deployed (currently `v=1`) |
| Logging | Each request logs host, total request count, uptime (seconds) and timestamp to stdout (`kubectl logs <pod>`) |

> `podname` is declared but unused; `host` is set once the server starts listening.

---

## 5. Container image (`Dockerfile`)

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY server.js .
EXPOSE 8081
CMD ["node", "server.js"]
```

| Instruction | Purpose |
|---|---|
| `FROM node:18-alpine` | Small Node 18 base image |
| `WORKDIR /app` | Working directory inside the container |
| `COPY server.js .` | Copies the only source file (no `npm install` needed – no dependencies) |
| `EXPOSE 8081` | Documents the listening port |
| `CMD ["node", "server.js"]` | Starts the app (exec form, so signals reach Node directly) |

### Build and run locally
```bash
docker build -t mbahvictor/ci-cd-pipeline:1.0 .
docker run -d --name ci-cd -p 8081:8081 mbahvictor/ci-cd-pipeline:1.0
curl localhost:8081
docker rm -f ci-cd
```

### Manual publish
```bash
docker login
docker push mbahvictor/ci-cd-pipeline:1.0
```

---

## 6. CI/CD pipeline (`Jenkinsfile`)

Declarative pipeline, runs on `agent any`.

### 6.1 Environment variables

| Variable | Value | Meaning |
|---|---|---|
| `IMAGE_NAME` | `mbahvictor/ci-cd-pipeline` | DockerHub repository |
| `IMAGE_TAG` | `1.0` | Image tag (fixed) |
| `PROD_SERVER` | `ubuntu@ec2-44-223-60-161.compute-1.amazonaws.com` | SSH target for deployment |
| `PROD_PLAYBOOK` | `k8s.yml` | Playbook executed on the Production Server |
| `DOCKER_CREDS` | `credentials('docker')` | Jenkins username/password credential; exposes `DOCKER_CREDS_USR` and `DOCKER_CREDS_PSW` |

### 6.2 Stages

| # | Stage | What it does | Fails when |
|---|---|---|---|
| 1 | **Checkout Source Code** | Clones `main` from GitHub | Repo unreachable / branch missing |
| 2 | **Build Docker Image** | `docker build -t mbahvictor/ci-cd-pipeline:1.0 .` | Dockerfile error, Docker not accessible to the `jenkins` user |
| 3 | **Test Container Launch** | Starts container `test-container` (`-p 8081:8081`), waits 10 s, checks it appears in `docker ps`, runs `docker exec … echo` inside it, then stops and removes it | Container exits, port 8081 already used, stale `test-container` exists |
| 4 | **Login to DockerHub** | `docker login` using the stored password via `--password-stdin` | Wrong credentials |
| 5 | **Push to DockerHub** | `docker push mbahvictor/ci-cd-pipeline:1.0` | Not logged in, no push rights to the `mbahvictor` namespace |
| 6 | **Deploy to Production via Ansible** | Uses `sshagent(['prod-ssh-key'])` to SSH into the Production Server and run `ansible-playbook k8s.yml` | SSH key missing/rejected, playbook error |

A `post` block prints a success or failure message.

### 6.3 Jenkins configuration required

| Setting | Value |
|---|---|
| Job type | Pipeline (script from SCM, or paste the Jenkinsfile) |
| Credential `docker` | Username with password – DockerHub |
| Credential `prod-ssh-key` | SSH private key for `ubuntu` on the Production Server |
| Plugins | Git, Pipeline, SSH Agent, Credentials Binding |
| Trigger | GitHub hook trigger for GITScm polling (webhook `http://<build-server>:8080/github-webhook/`) or Poll SCM |
| OS access | `jenkins` user in the `docker` group |

### 6.4 Why the test stage satisfies the "build test" requirement
It proves the image can be *launched and is running*: the container must still be up after 10 seconds (`docker ps | grep`) and must accept a command (`docker exec`). No functional testing of the app is done, as the brief specified.

---

## 7. Production server and Kubernetes

The Production Server is configured with **Ansible** (run locally on the server):

| Playbook | Responsibility |
|---|---|
| kubectl playbook | Installs `kubectl` |
| Minikube playbook | Installs and starts Minikube (Docker driver) |
| `k8s.yml` | Deploys `mbahvictor/ci-cd-pipeline` from DockerHub, creates a NodePort Service, sets replicas for rolling updates; run by Jenkins on every deployment |

> The playbooks were not included with the files used to write this document. **Paste their contents here** to complete this section, for example:
>
> ```yaml
> # k8s.yml
> <paste your playbook>
> ```

### Kubernetes objects

| Object | Role |
|---|---|
| Deployment | Runs several replicas of the pod; `RollingUpdate` strategy replaces pods gradually so the service stays available |
| Service (NodePort) | Exposes the pods on a port of the Minikube node, load-balancing across replicas |

**Why several replicas:** with a single replica there is no spare pod to serve traffic while a new one starts. Multiple replicas plus `maxUnavailable`/`maxSurge` limits mean old pods are removed only when replacements are ready.

---

## 8. Setup guide

### 8.1 Build Server
```bash
sudo apt update && sudo apt install -y git docker.io fontconfig openjdk-17-jre
sudo systemctl enable --now docker
# Install Jenkins from the official apt repository, then:
sudo usermod -aG docker jenkins && sudo systemctl restart jenkins
```
Configure Git/GitHub SSH authentication:
```bash
git config --global user.name  "<name>"
git config --global user.email "<email>"
ssh-keygen -t ed25519 -C "<email>"      # add the .pub key to GitHub
```
Open port **8080** in the EC2 security group and finish Jenkins setup at `http://<build-server-ip>:8080`.

### 8.2 Production Server
```bash
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible
```
Then run the Ansible playbooks to install kubectl and Minikube and to deploy the app.

### 8.3 SSH trust between servers
Add the public half of the `prod-ssh-key` key pair to `~ubuntu/.ssh/authorized_keys` on the Production Server, and the private half to Jenkins credentials.

---

## 9. Usage and verification

### Trigger a release
1. Edit `response.end(" | v=1\n");` in `server.js` – increment the version (e.g. `v=2`).
2. Commit and push:
   ```bash
   git commit -am "Bump to v=2"
   git push origin main
   ```
3. Jenkins runs automatically. In the **Console Output** look for:
   - `docker build` – image created
   - `docker push` – image pushed to DockerHub
   - `ansible-playbook k8s.yml` – update issued to Kubernetes

### Verify on the Production Server
```bash
curl $(minikube ip):<node-port>     # → DevOps Coursework 2! | Running on: <pod> | v=2
kubectl get pods --watch            # watch pods being replaced
kubectl get svc
kubectl logs <pod-name>             # per-request log lines
```

---

## 10. Known issues and recommended improvements

Found while reviewing the supplied files.

| # | Issue | Impact | Suggested fix |
|---|---|---|---|
| 1 | **DockerHub username mismatch** – image is `mbahvictor/…` but the login stage uses `-u "mbahvictor"` | Push fails if `mbahvictor` and `mbahvictor` are different accounts, or if `mbahvictor` can't write to `mbahvictor` | Log in as the account that owns the repo, and use `$DOCKER_CREDS_USR` instead of a hard-coded name |
| 2 | **Fixed tag `1.0`** for every build | Kubernetes may not roll out a new image when the tag is unchanged (cached image, no spec change), so the update may not actually happen unless the playbook forces it | Tag with `${BUILD_NUMBER}` and pass it to the playbook / `kubectl set image`, or have the playbook run `kubectl rollout restart` with `imagePullPolicy: Always` |
| 3 | **Secret interpolated in a double-quoted Groovy string** (`$DOCKER_CREDS_PSW`) | Jenkins warns about insecure secret interpolation | Use a single-quoted `sh '''…'''` block so the shell expands it |
| 4 | **Stale test container** – a failed run leaves `test-container` behind | Next build fails on the name clash | Add `post { always { sh 'docker rm -f test-container \|\| true' } }` to the test stage |
| 5 | **Host port 8081 in test stage** | Fails if anything else uses 8081 on the Build Server | Drop `-p 8081:8081` (not needed for the test) |
| 6 | **`StrictHostKeyChecking=no`** | Weakens SSH host verification | Pre-populate `known_hosts` on the Build Server |
| 7 | **Hard-coded EC2 hostname** | Changes if the instance is stopped/started | Use an Elastic IP or a Jenkins parameter |
| 8 | **Separate Login stage** | Docker login state is workspace/host-wide | Use `withCredentials`/`docker.withRegistry` around the push |

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `permission denied … docker.sock` in Jenkins | `jenkins` not in `docker` group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| Jenkins UI unreachable | Port 8080 closed | Open it in the EC2 security group |
| `denied: requested access to the resource is denied` on push | Wrong DockerHub user/namespace | See issue 1 |
| `Conflict. The container name "/test-container" is already in use` | Previous run failed mid-stage | `docker rm -f test-container` |
| Deploy stage: `Permission denied (publickey)` | Key not authorised on Production Server | See §8.3 |
| Pods `ImagePullBackOff` | Wrong image name/tag or private repo | Check `kubectl describe pod` |
| `curl $(minikube ip):<port>` hangs | Wrong NodePort or Minikube stopped | `kubectl get svc`, `minikube status` |
| Pipeline succeeds but version doesn't change | Same tag reused | See issue 2 |