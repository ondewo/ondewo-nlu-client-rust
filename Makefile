export
# =====================================================================================
# ondewo-nlu-client-rust - Makefile
#
# The ONDEWO NLU (Natural Language Understanding) gRPC client for rust. The crate is generated
# from the protos of the ondewo-nlu-api submodule by the ondewo-rust-proto-compiler image that
# the ondewo-proto-compiler submodule builds - only src/api is generated, everything else in
# this repository is hand-written.
#
# Quick start:
#   make help                 # list every documented target
#   make makefile_chapters    # list the section headers below
#   make build                # submodules -> compiler image -> stubs -> cargo build (in the utils image)
#   make test                 # cargo test with a local rust toolchain
#   make test_via_docker      # the same in the utils image - needs only docker
#
# The host needs only make, git, docker, perl and curl: the stubs are generated in the compiler
# image, and every cargo and gh step of `build` and `release` runs in the utils image built from
# Dockerfile.utils (the *_via_docker* targets).
# =====================================================================================

# ---------------- BEFORE RELEASE ----------------
# 1 - Update the version number (ONDEWO_NLU_VERSION below)
# 2 - Update RELEASE.md
# 3 - make build
# (`make release_all_clients` in ondewo-nlu-api does 1 and 2 and then runs `make ondewo_release`.)
# -------------- Release Process Steps (`make ondewo_release`, all of it local) --------------
# 1 - Write the version into Cargo.toml, Cargo.lock and README.md; check branch and tag are new
# 2 - Get Credentials from devops-accounts repo (the ONLY source of credentials)
# 3 - Check the credentials: set, and the GitHub token may push to this repository
# 4 - Check crates.io does not have the version yet and RELEASE.md has its notes
# 5 - Build, test and crates.io dry run in docker, then commit
# 6 - Push, Create Release Branch and push, Create Release Tag and push
# 7 - crates.io Release (cargo publish in the utils image)
# 8 - GitHub Release - LAST, so that it only exists for a complete release

########################################################
# 		Variables
########################################################

# MUST BE THE SAME AS THE NLU API IN MAJOR AND MINOR VERSION NUMBER
# example: API 2.9.0 --> Client 2.9.X
ONDEWO_NLU_VERSION=7.3.0

# Submodule pins - `make checkout_defined_submodule_versions` checks out exactly these.
# Pin the API to `tags/<api version>` before cutting a release; a branch is for development only.
ONDEWO_NLU_API_GIT_BRANCH=tags/7.3.0
# The compiler has to be 5.15.2 or newer: an older image builds its crate without the README.md
# that Cargo.toml's `readme` names, and its `cargo package` fails every generation run.
ONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/5.15.2

# Submodule directories - these MUST match the paths in .gitmodules
ONDEWO_NLU_API_DIR=ondewo-nlu-api
ONDEWO_PROTO_COMPILER_DIR=ondewo-proto-compiler

# The generation contract with the proto compiler. The image TAG is the only contract between
# this repository and the compiler - `make build_compiler` rebuilds it from the submodule.
# The image ENTRYPOINT takes two positional arguments, BOTH relative to /input-volume:
#   <relative_protos_dir>   the protoc -I root every `import "x/y.proto";` resolves against
#   <target_subdir>         the sub-directory whose protos are the compilation entry points;
#                           google/ is pulled in only as a resolved dependency
PROTO_COMPILER_IMAGE=ondewo-rust-proto-compiler:latest
ONDEWO_PROTOS_DIR=${ONDEWO_NLU_API_DIR}
ONDEWO_PROTOS_TARGET_DIR=ondewo

# Staging directory that is handed to the image as /input-volume (see generate_ondewo_protos)
PROTO_INPUT_DIR=.proto-input

# The utils image (Dockerfile.utils): the rust toolchain and the GitHub CLI. Every *_via_docker*
# target runs a plain target of THIS Makefile in it, so neither cargo nor gh is needed on the host.
IMAGE_UTILS_NAME=ondewo-nlu-client-utils-rust:${ONDEWO_NLU_VERSION}
# The run prefix of those targets - append any `-e <CREDENTIAL>`, then ${IMAGE_UTILS_NAME} and the
# command. The repository is MOUNTED, not copied, so build output lands in this working tree, and
# --user keeps it owned by the caller instead of root. HOME and CARGO_HOME point at paths that uid
# can write; CARGO_HOME sits under the git-ignored target/, so the downloaded crates survive from one
# container to the next and never reach `cargo package`. A bare `-e NAME` forwards the variable from
# the environment (line 1 `export`s every make variable), so no credential is spelled out in a command.
UTILS_DOCKER_RUN=docker run --rm \
	--user $$(id -u):$$(id -g) \
	-e HOME=/tmp/home \
	-e CARGO_HOME=/home/ondewo/target/docker-cargo-home \
	-v $(CURDIR):/home/ondewo \
	-w /home/ondewo

# Coverage gate - KEEP IN SYNC with .github/workflows/ci.yml, which runs the same two values.
# Excluded from the metric: the generated stubs (machine output, not authored logic) and the
# tests/examples themselves (the measuring instrument).
COVERAGE_EXCLUDE_REGEX=(^|/)(src/api/|tests/|examples/)
COVERAGE_MIN_LINES=100

# The two release credentials live ONLY in the ondewo-devops-accounts repository: `make ondewo_release`
# clones it, and run_release_with_devops hands GITHUB_GH_TOKEN (account_github.env) and
# CARGO_REGISTRY_TOKEN (account_cargo.env, a crates.io token with the publish-update scope) to
# `make release`. The placeholders make a release without them stop at check_release_credentials,
# before anything is built or pushed. cargo reads CARGO_REGISTRY_TOKEN from the environment (this
# Makefile `export`s every variable), so it never appears on a command line or in the build log.
GITHUB_GH_TOKEN?=ENTER_YOUR_TOKEN_HERE
CARGO_REGISTRY_TOKEN?=ENTER_HERE_YOUR_CARGO_REGISTRY_TOKEN

# The target run_release_with_devops runs with those credentials: `release`, or its post-push half
# `release_publish` when ondewo_release_publish resumes a release that stopped after its tag push.
RELEASE_TARGET=release

# The public crates.io API record of this version: HTTP 200 once it is published, 404 before. No
# credential is involved; crates.io asks every API client for a User-Agent that names it
# (https://crates.io/data-access), so this one names the repository and nothing else.
CRATES_IO_VERSION_URL=https://crates.io/api/v1/crates/ondewo-nlu-client/${ONDEWO_NLU_VERSION}
CRATES_IO_VERSION_HTTP_CODE=curl -sS -o /dev/null -w '%{http_code}' -A 'ondewo-nlu-client-rust release (https://github.com/ondewo/ondewo-nlu-client-rust)' ${CRATES_IO_VERSION_URL}

# crates.io refuses an upload whose .crate tarball is larger than this (10 MiB, the default limit).
# The check is server-side, so `cargo publish --dry-run` cannot catch it - publish_crate_dry_run does.
CRATE_MAX_BYTES=10485760

# Terminate on the ***** separator that delimits release entries, NOT on /\*\*/ - that matches the
# first markdown **bold** span inside the entry and silently truncates the notes there, with no
# error from `gh release create`.
CURRENT_RELEASE_NOTES=`cat RELEASE.md \
	| perl -ne 'print if /Release ONDEWO NLU Rust Client ${ONDEWO_NLU_VERSION}/../^\*{5}/'`

GH_REPO="https://github.com/ondewo/ondewo-nlu-client-rust"
DEVOPS_ACCOUNT_GIT="ondewo-devops-accounts"
DEVOPS_ACCOUNT_DIR="./${DEVOPS_ACCOUNT_GIT}"

# Define colors globally (reused for [INFO]/[SUCCESS]/[WARN]/[ERROR] log lines in recipes)
BLUE   := \033[1;34m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

.DEFAULT_GOAL := help

########################################################
#       ONDEWO Standard Make Targets
########################################################

setup_developer_environment_locally: install_rust_toolchain install_precommit_hooks ## Ready a fresh laptop: rust toolchain + pre-commit hooks

install_rust_toolchain: ## Install rustup/cargo if missing and add the rustfmt and clippy components
	@command -v cargo >/dev/null 2>&1 || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# rustup's installer puts cargo on PATH for NEW shells only, so source its env for this one -
# otherwise the very first run of this target installs rustup and then cannot call it.
	[ -f "$$HOME/.cargo/env" ] && . "$$HOME/.cargo/env"; rustup component add rustfmt clippy

install_precommit_hooks: ## Installs pre-commit hooks and sets them up for the ondewo-nlu-client-rust repo
	@command -v pre-commit >/dev/null 2>&1 || uv tool install pre-commit || pipx install pre-commit || pip install --user pre-commit
	pre-commit install
	pre-commit install --hook-type commit-msg

precommit_hooks_run_all_files: ## Runs all pre-commit hooks on all files and not just the changed ones
	pre-commit run --all-files

help: ## Print usage info about help targets
	# (first comment after target starting with double hashes ##)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

makefile_chapters: ## Shows all sections of Makefile
	@echo `cat Makefile| grep "########################################################" -A 1 | grep -v "########################################################"`

TEST: ## Prints some important variables
	@echo "Release Notes: \n \n$(CURRENT_RELEASE_NOTES)"
	@echo "GH Token: \t $(if $(filter-out ENTER_YOUR_TOKEN_HERE,$(GITHUB_GH_TOKEN)),<set>,<unset>)"
	@echo "Cargo Token: \t $(if $(filter-out ENTER_HERE_YOUR_CARGO_REGISTRY_TOKEN,$(CARGO_REGISTRY_TOKEN)),<set>,<unset>)"
	@echo "Compiler Image:  $(PROTO_COMPILER_IMAGE)"
	@echo "Utils Image: \t $(IMAGE_UTILS_NAME)"
	@echo "Protos: \t $(ONDEWO_PROTOS_DIR)/$(ONDEWO_PROTOS_TARGET_DIR)"

check_build: ## Checks if all built proto-code is there
# prost writes ONE file per proto PACKAGE (flat_output_dir), named "<package>.rs" - so the
# check is per package, not per .proto file, and src/api/mod.rs is the barrel that includes them.
	@rm -f build_check.txt
	@find ${ONDEWO_PROTOS_DIR}/${ONDEWO_PROTOS_TARGET_DIR} -type f -name "*.proto" -exec sed -n 's|^[[:space:]]*package[[:space:]][[:space:]]*\([A-Za-z0-9_.]*\)[[:space:]]*;.*|\1|p' {} \; > build_check.txt
	@sort -u build_check.txt -o build_check.txt
	@test -s build_check.txt || { echo "$(RED)[ERROR]$(NC) No proto packages found under ${ONDEWO_PROTOS_DIR}/${ONDEWO_PROTOS_TARGET_DIR}"; rm -f build_check.txt; exit 1; }
	@test -f src/api/mod.rs || { echo "$(RED)[ERROR]$(NC) src/api/mod.rs is missing - run 'make generate_ondewo_protos'"; rm -f build_check.txt; exit 1; }
	@while read -r package; do \
		test -f "src/api/$$package.rs" || { echo "$(RED)[ERROR]$(NC) No rust stub for proto package $$package (expected src/api/$$package.rs)"; rm -f build_check.txt; exit 1; }; \
	done < build_check.txt
	@rm -f build_check.txt
	@echo "$(GREEN)[SUCCESS]$(NC) A generated stub exists for every proto package"

########################################################
#       Repo Specific Make Targets
########################################################
#		Build

build: update_submodules checkout_defined_submodule_versions build_compiler update_cargo_version generate_ondewo_protos check_build cargo_build_via_docker ## Build source code: submodules -> compiler image -> stubs -> cargo build (in the utils image)
	@echo "$(GREEN)[SUCCESS]$(NC) Build of ondewo-nlu-client-rust ${ONDEWO_NLU_VERSION} finished"

build_compiler: ## Build proto compiler docker image from the ondewo-proto-compiler submodule
	@echo "$(BLUE)[INFO]$(NC) Building ${PROTO_COMPILER_IMAGE} from ${ONDEWO_PROTO_COMPILER_DIR}/rust ..."
# The image COPYs image-data/ with the checkout's file modes, and generate_ondewo_protos runs it as
# the invoking user, not root: a checkout made under `umask 077` (the release log recipe) leaves its
# entrypoint root-owned 0600 in there - the image's `chmod -R a+w` adds no read - and generation dies
# with "compile-proto-2-rust.sh: Permission denied". a+rX only adds read, and search on directories;
# git tracks neither, so the submodule stays clean.
	chmod -R a+rX ${ONDEWO_PROTO_COMPILER_DIR}/rust
	cd ${ONDEWO_PROTO_COMPILER_DIR}/rust && sh build.sh
	@echo "$(GREEN)[SUCCESS]$(NC) Built ${PROTO_COMPILER_IMAGE}"

generate_ondewo_protos: ## Generate rust code from proto files into src/api
	@echo "$(BLUE)[INFO]$(NC) Generating rust stubs from ${ONDEWO_PROTOS_DIR}/${ONDEWO_PROTOS_TARGET_DIR} ..."
	@test -d ${ONDEWO_PROTOS_DIR}/${ONDEWO_PROTOS_TARGET_DIR} || { echo "$(RED)[ERROR]$(NC) '${ONDEWO_PROTOS_DIR}/${ONDEWO_PROTOS_TARGET_DIR}' is missing - run 'make update_submodules' first"; exit 1; }
# The image COPIES the whole mounted input volume into itself before it compiles, so the repo
# root is deliberately not the input volume: it carries target/ (gigabytes after a release
# build) and .git. Stage exactly what the image consumes instead - the protos, the crate
# manifest, the README.md its `readme` names (the image's `cargo package` refuses the crate
# without it) and the hand-written sources. src/api is left out on purpose: it is entirely
# generated, and the image wipes it in the output volume before copying the new stubs back.
	rm -rf ${PROTO_INPUT_DIR}
	mkdir -p ${PROTO_INPUT_DIR}/src
	cp Cargo.toml README.md ${PROTO_INPUT_DIR}/
	find src -mindepth 1 -maxdepth 1 ! -name api -exec cp -R {} ${PROTO_INPUT_DIR}/src/ \;
	cp -R ${ONDEWO_PROTOS_DIR} ${PROTO_INPUT_DIR}/${ONDEWO_PROTOS_DIR}
# Same image tag and the same positional arguments as the compiler's own
# ondewo-proto-compiler/rust/example/run-compile.sh. Two deliberate differences:
#  * NO -it - a TTY-enabled container breaks every non-interactive caller with
#    "cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
#  * --user, as in ondewo-proto-compiler/rust/Makefile, so the generated src/api,
#    Cargo.toml, Cargo.lock and crate-dist/ are owned by the caller and not by root.
#    The image chmods its working directories a+w so this works.
# The output volume is the repository root, because the crate IS this repository.
	docker run --rm \
		--user ${shell id -u}:${shell id -g} \
		-v ${shell pwd}/${PROTO_INPUT_DIR}:/input-volume \
		-v ${shell pwd}:/output-volume \
		${PROTO_COMPILER_IMAGE} ${ONDEWO_PROTOS_DIR} ${ONDEWO_PROTOS_TARGET_DIR}
	rm -rf ${PROTO_INPUT_DIR}
	@echo "$(GREEN)[SUCCESS]$(NC) Generated the rust stubs in src/api"

update_cargo_version: ## Write ONDEWO_NLU_VERSION into Cargo.toml, the crate's entry in Cargo.lock and the README install snippet
# ondewo_release runs this BEFORE spc: ondewo-nlu-api's release_client sets this Makefile's
# ONDEWO_NLU_VERSION but touches none of the three files below, and spc refuses a Cargo.toml that
# still carries the old version.
# Cargo.lock has to follow, or `cargo publish --locked` refuses the lockfile the release commit
# carries - the first 7.1.0 tag failed its `cargo build --locked` that way. The README pins the minor.
	@perl -0pi -e 's/(\[package\][^\[]*?\nversion = ")[^"]*(")/$${1}${ONDEWO_NLU_VERSION}$${2}/s' Cargo.toml
	@perl -0pi -e 's/(\[\[package\]\]\nname = "ondewo-nlu-client"\nversion = ")[^"]*(")/$${1}${ONDEWO_NLU_VERSION}$${2}/' Cargo.lock
	@perl -pi -e 'BEGIN { ($$minor) = "${ONDEWO_NLU_VERSION}" =~ /^(\d+\.\d+)\./ } s/^(ondewo-nlu-client = "~)[^"]*(")/$${1}$$minor$${2}/' README.md
	@echo "$(GREEN)[SUCCESS]$(NC) Cargo.toml, Cargo.lock and README.md set to ${ONDEWO_NLU_VERSION}"

cargo_build: ## Compile the crate in release mode
	cargo build --release

test: ## Run the test suite (--all-targets also compiles examples/)
	cargo test --all-targets

coverage: ## Line coverage of the HAND-WRITTEN sources, gated at COVERAGE_MIN_LINES (as in CI)
# src/api is machine output and tests/ + examples/ are the measuring instrument, so neither
# belongs in the metric - what remains is exactly the hand-written library surface. The generated
# stubs are still exercised, by the behavioural tests under tests/.
	@command -v cargo-llvm-cov >/dev/null 2>&1 || { echo "$(RED)[ERROR]$(NC) cargo-llvm-cov is missing - install it with 'cargo install cargo-llvm-cov --locked'"; exit 1; }
	cargo llvm-cov --summary-only \
		--ignore-filename-regex '${COVERAGE_EXCLUDE_REGEX}' \
		--fail-under-lines ${COVERAGE_MIN_LINES}

cargo_fmt: ## Format the hand-written sources (src/api is generated and never hand-formatted)
	find src tests examples -name "*.rs" -not -path "src/api/*" -exec rustfmt --edition 2021 {} +

# The same file set as the rustfmt step of .github/workflows/ci.yml: src, tests and examples.
cargo_fmt_check: ## Check the formatting of the hand-written sources without changing them
	find src tests examples -name "*.rs" -not -path "src/api/*" -exec rustfmt --check --edition 2021 {} +

cargo_doc: ## Build the crate documentation
	cargo doc --no-deps

clean_generated_api: ## Clear the generated stubs in src/api
	rm -rf src/api

clean: ## Remove cargo build output, the packaged crate and the generation staging directory
	cargo clean
	rm -rf crate-dist ${PROTO_INPUT_DIR} build_check.txt

########################################################
#		Utils image

build_utils_docker_image: ## Build the utils image (rust toolchain + gh) that every *_via_docker* target runs in
	docker build -f Dockerfile.utils -t ${IMAGE_UTILS_NAME} .

cargo_build_via_docker: build_utils_docker_image ## Run `make cargo_build` in the utils image - needs only docker
	${UTILS_DOCKER_RUN} ${IMAGE_UTILS_NAME} make cargo_build

test_via_docker: build_utils_docker_image ## Run `make test` in the utils image - needs only docker
	${UTILS_DOCKER_RUN} ${IMAGE_UTILS_NAME} make test

publish_crate_dry_run_via_docker: build_utils_docker_image ## Run `make publish_crate_dry_run` in the utils image - needs only docker
	${UTILS_DOCKER_RUN} ${IMAGE_UTILS_NAME} make publish_crate_dry_run

publish_crate_via_docker: build_utils_docker_image ## Run `make publish_crate` in the utils image (needs CARGO_REGISTRY_TOKEN)
	@${UTILS_DOCKER_RUN} -e CARGO_REGISTRY_TOKEN ${IMAGE_UTILS_NAME} make publish_crate

########################################################
#		Submodules

update_submodules: ## Initialize and update all submodules
	@echo "$(BLUE)[INFO]$(NC) START initializing submodules ..."
	git submodule update --init --recursive
	@echo "$(GREEN)[SUCCESS]$(NC) DONE initializing submodules"

checkout_defined_submodule_versions: ## Update submodule versions to the pins at the top of this Makefile
	@echo "$(BLUE)[INFO]$(NC) START checking out submodules ..."
	git -C ${ONDEWO_NLU_API_DIR} fetch --all
	git -C ${ONDEWO_NLU_API_DIR} checkout ${ONDEWO_NLU_API_GIT_BRANCH}
	git -C ${ONDEWO_PROTO_COMPILER_DIR} fetch --all
	git -C ${ONDEWO_PROTO_COMPILER_DIR} checkout ${ONDEWO_PROTO_COMPILER_GIT_BRANCH}
	@echo "$(GREEN)[SUCCESS]$(NC) DONE checking out submodules"

########################################################
#		Release

check_release_credentials: check_gh_token check_cargo_token ## Fail loudly when a release credential is unset or still a placeholder

# Both token checks read the token through the SHELL ($$VAR - this Makefile exports everything),
# never through make ($(VAR)), so it is not interpolated into the recipe text and cannot reach the log.
check_gh_token: ## Fail loudly when GITHUB_GH_TOKEN is unset or still the placeholder
	@test -n "$$GITHUB_GH_TOKEN" -a "$$GITHUB_GH_TOKEN" != "ENTER_YOUR_TOKEN_HERE" || { echo "$(RED)[ERROR]$(NC) GITHUB_GH_TOKEN is not set - run 'make ondewo_release', which reads it from account_github.env of ${DEVOPS_ACCOUNT_GIT}"; exit 1; }
	@echo "$(GREEN)[SUCCESS]$(NC) GITHUB_GH_TOKEN is set"

check_cargo_token: ## Fail loudly when CARGO_REGISTRY_TOKEN is unset or still the placeholder
	@test -n "$$CARGO_REGISTRY_TOKEN" -a "$$CARGO_REGISTRY_TOKEN" != "ENTER_HERE_YOUR_CARGO_REGISTRY_TOKEN" || { echo "$(RED)[ERROR]$(NC) CARGO_REGISTRY_TOKEN is not set - run 'make ondewo_release', which reads it from account_cargo.env of ${DEVOPS_ACCOUNT_GIT}"; exit 1; }
	@echo "$(GREEN)[SUCCESS]$(NC) CARGO_REGISTRY_TOKEN is set"

check_crate_version_unpublished: ## Fail unless crates.io still lacks ONDEWO_NLU_VERSION (public API, no credential)
# crates.io versions are immutable: a version it already has passes every other check and then
# fails the upload, after the release branch and the tag are pushed.
	@code=`$(CRATES_IO_VERSION_HTTP_CODE)`; \
	case "$$code" in \
		404) echo "$(GREEN)[SUCCESS]$(NC) crates.io does not have ondewo-nlu-client ${ONDEWO_NLU_VERSION} yet";; \
		200) echo "$(RED)[ERROR]$(NC) crates.io already has ondewo-nlu-client ${ONDEWO_NLU_VERSION} - its versions are immutable, release a new one"; exit 1;; \
		*) echo "$(RED)[ERROR]$(NC) could not ask crates.io whether it has ondewo-nlu-client ${ONDEWO_NLU_VERSION} (HTTP $$code from ${CRATES_IO_VERSION_URL})"; exit 1;; \
	esac

check_release_tree_clean: ## Fail unless the working tree is fully committed - cargo publish uploads only a committed tree
# `release` runs this between its commit and its first push. `cargo publish` refuses a crate with
# uncommitted changes, and in `release` it runs only AFTER the tag push - so anything the build or
# the pre-commit hooks changed outside the `git add` list of `release` has to stop the release
# here, while origin is untouched. Submodule working trees are ignored (the crate excludes both
# submodules); a changed submodule COMMIT is not.
	@dirty=`git status --porcelain --ignore-submodules=dirty`; \
	test -z "$$dirty" || { echo "$(RED)[ERROR]$(NC) the release commit left these changes behind - nothing has been pushed:"; echo "$$dirty"; exit 1; }
	@echo "$(GREEN)[SUCCESS]$(NC) The release commit carries the whole working tree"

release: ## Automate the entire release process - all of it locally, cargo and gh in the utils image
	@echo "Start Release"
# Everything that can be refuted without touching origin is refuted FIRST: a credential that is
# missing or that GitHub rejects, a version crates.io already has, a missing RELEASE.md entry, and
# a failing build, test or packaging dry run. Found after the pushes below, any of them would leave
# a release branch and a tag on origin that `spc` then refuses to create again.
#
# CARGO_REGISTRY_TOKEN is only checked for presence. crates.io documents no read-only endpoint
# that accepts a publish-scoped API token (https://crates.io/api/openapi.json), so the upload itself
# is the first thing that can prove it; `make ondewo_release_publish` resumes a release that
# stopped there.
	make check_release_credentials
	make build_utils_docker_image
	make validate_release_credentials_via_docker_image
	make check_crate_version_unpublished
	make check_release_notes
	make build
	make test_via_docker
	make publish_crate_dry_run_via_docker
	-make precommit_hooks_run_all_files
	git status
	make check_build
	git add Cargo.toml
# Cargo.lock is what `cargo publish --locked` builds the uploaded crate against.
	git add Cargo.lock
# src/ carries BOTH the generated stubs (src/api) and every hand-written module beside them.
	git add src
	git add Makefile
	git add README.md
	git add RELEASE.md
# tests/ is not packaged, but leaving it out of the release commit means a regression test
# written alongside a fix never reaches the repository and CI never runs it.
	-git add tests
	git add ${ONDEWO_PROTO_COMPILER_DIR}
	git add ${ONDEWO_NLU_API_DIR}
	git status
# Not `-git commit`: a commit that FAILS (no git identity, say) must stop the release instead of
# letting it tag the previous commit. Only "nothing staged" is allowed through.
	git diff --cached --quiet || git commit --no-verify -m "PREPARING FOR RELEASE ${ONDEWO_NLU_VERSION}"
	make check_release_tree_clean
	git push
	make create_release_branch
	make create_release_tag
	make release_publish
	@echo "Release Finished"

release_publish: ## The post-push half of `release`: the crates.io upload, then the GitHub release (needs both tokens)
# cargo and gh run in the utils image, which `release` has already built - so nothing after the tag
# push depends on docker pulling or apt installing anything. The GitHub release comes LAST, so that
# it only exists for a complete release. The upload is irreversible, so when ondewo_release_publish
# resumes, it first proves that HEAD is the release tag and not some later commit of master.
	@test "`git rev-parse HEAD`" = "`git rev-parse -q --verify '${ONDEWO_NLU_VERSION}^{commit}'`" || { echo "$(RED)[ERROR]$(NC) HEAD is not the release tag ${ONDEWO_NLU_VERSION} - run this in the checkout the release left behind or in a clone of that tag; nothing was uploaded"; exit 1; }
	make publish_crate_via_docker
	make release_to_github_via_docker_image

create_release_branch: ## Create Release Branch and push it to origin
	git checkout -b "release/${ONDEWO_NLU_VERSION}"
	git push -u origin "release/${ONDEWO_NLU_VERSION}"

create_release_tag: ## Create Release Tag and push it to origin
	git tag -a ${ONDEWO_NLU_VERSION} -m "release/${ONDEWO_NLU_VERSION}"
	git push origin ${ONDEWO_NLU_VERSION}

########################################################
#		GITHUB

push_to_gh: login_to_gh build_gh_release ## Logs into GitHub CLI and Releases
	@echo 'Released to Github'

release_to_github_via_docker: build_utils_docker_image release_to_github_via_docker_image ## Build the utils image and create the GitHub release in it

release_to_github_via_docker_image: ## Run `make push_to_gh` in the utils image (needs the image built and GITHUB_GH_TOKEN)
	@${UTILS_DOCKER_RUN} -e GITHUB_GH_TOKEN ${IMAGE_UTILS_NAME} make push_to_gh

validate_release_credentials_via_docker_image: ## Run `make validate_release_credentials` in the utils image (needs the image built and GITHUB_GH_TOKEN)
	@${UTILS_DOCKER_RUN} -e GITHUB_GH_TOKEN ${IMAGE_UTILS_NAME} make validate_release_credentials

validate_release_credentials: login_to_gh ## Fail unless GitHub accepts GITHUB_GH_TOKEN and it may push to this repository (read-only)
# Read-only proof that the token carries the GitHub release after the tag push: the very `gh auth
# login` that push_to_gh runs (it rejects an unknown, expired or revoked token with "HTTP 401: Bad
# credentials", and a classic token without the repo or read:org scope), then GitHub's own verdict
# on push access to this repository. Nothing is written to GitHub, and the gh config lives only in
# the throw-away container. CARGO_REGISTRY_TOKEN has no such check - see `release`.
	@push=`gh api repos/ondewo/ondewo-nlu-client-rust --jq .permissions.push` || { echo "$(RED)[ERROR]$(NC) GitHub rejected GITHUB_GH_TOKEN - nothing has been pushed"; exit 1; }; \
	test "$$push" = true || { echo "$(RED)[ERROR]$(NC) GITHUB_GH_TOKEN has no push access to ondewo/ondewo-nlu-client-rust (permissions.push: '$$push') - nothing has been pushed"; exit 1; }
	@echo "$(GREEN)[SUCCESS]$(NC) GITHUB_GH_TOKEN may push to ondewo/ondewo-nlu-client-rust"

login_to_gh: check_gh_token ## Login to Github CLI with Access Token
	@echo $(GITHUB_GH_TOKEN) | gh auth login -p ssh --with-token

check_release_notes: ## Assert RELEASE.md carries an entry for ONDEWO_NLU_VERSION
# `gh release create -n ""` succeeds and publishes an EMPTY release, so an entry that was
# forgotten - or a heading whose wording drifted away from what CURRENT_RELEASE_NOTES greps for -
# is otherwise only noticed by whoever reads the release page afterwards.
	@notes="$(CURRENT_RELEASE_NOTES)"; \
	if [ -z "$$notes" ]; then \
		echo "$(RED)[ERROR]$(NC) RELEASE.md has no '## Release ONDEWO NLU Rust Client ${ONDEWO_NLU_VERSION}' entry"; \
		echo "        The GitHub release would be created with empty notes - add the entry first."; \
		exit 1; \
	fi; \
	echo "$(GREEN)[SUCCESS]$(NC) RELEASE.md has release notes for ${ONDEWO_NLU_VERSION}"

build_gh_release: check_release_notes ## Generate Github Release with CLI
	gh release create --repo $(GH_REPO) "$(ONDEWO_NLU_VERSION)" -n "$(CURRENT_RELEASE_NOTES)" -t "Release ${ONDEWO_NLU_VERSION}"

########################################################
#		CRATES.IO

check_crate_metadata: ## Assert Cargo.toml carries everything crates.io requires of a publishable crate
# `cargo publish --dry-run` already rejects an empty description/license/repository and a missing
# readme file, but it says nothing about keywords/categories (crates.io only recommends those) and
# it cannot see the server-side size limit. Keeping the whole list in one credential-free target
# means `release` checks every one of them (through publish_crate_dry_run) before its first push,
# instead of crates.io refusing the upload after the tag is out.
	@for field in description license repository readme; do \
		grep -Eq "^$$field = \"[^\"]+\"" Cargo.toml || { echo "$(RED)[ERROR]$(NC) Cargo.toml carries no non-empty '$$field' - crates.io refuses the upload without it"; exit 1; }; \
	done
	@grep -Eq '^keywords = \[[^]]+\]' Cargo.toml || { echo "$(RED)[ERROR]$(NC) Cargo.toml carries no 'keywords' - the crate would be unfindable on crates.io"; exit 1; }
	@grep -Eq '^categories = \[[^]]+\]' Cargo.toml || { echo "$(RED)[ERROR]$(NC) Cargo.toml carries no 'categories' - the crate would be unfindable on crates.io"; exit 1; }
	@! grep -Eq '^[[:space:]]*publish[[:space:]]*=[[:space:]]*false' Cargo.toml || { echo "$(RED)[ERROR]$(NC) Cargo.toml sets 'publish = false' - the crate cannot be published at all"; exit 1; }
	@readme=`sed -n 's|^readme = "\(.*\)"|\1|p' Cargo.toml | head -n 1`; \
		test -s "$$readme" || { echo "$(RED)[ERROR]$(NC) the readme '$$readme' declared in Cargo.toml is missing or empty - crates.io renders it as the crate page"; exit 1; }
	@echo "$(GREEN)[SUCCESS]$(NC) Cargo.toml carries every field crates.io requires"

publish_crate_dry_run: check_crate_metadata ## Credential-free run of the whole packaging path, minus the upload (`release` runs it before its first push)
# Everything the crates.io release does except the upload itself, and none of it needs a token.
# --allow-dirty throughout because `release` runs this over a working tree with freshly generated
# stubs, before its commit; the real publish_crate deliberately has no such flag and refuses a
# dirty tree, which is why `release` runs check_release_tree_clean before it pushes.
#
# First the exact file list crates.io would receive. The readme needs no assertion here: cargo
# always packages the file named by `readme`, even against an exclude entry, and
# check_crate_metadata has already proven that file exists and is non-empty.
	@echo "$(BLUE)[INFO]$(NC) Files that would be published:"
	cargo package --list --allow-dirty
# `cargo publish --dry-run` builds its tarball in a scratch directory and does not leave it behind,
# so the size limit is measured on the one `cargo package` writes. --no-verify keeps this step to
# the tarball alone (seconds); the compile that proves the packaged copy builds is the dry run below.
	cargo package --no-verify --allow-dirty
# Name the tarball from the manifest rather than globbing target/package: a cached build directory
# can still hold the .crate of an earlier version, and a glob would happily measure that one.
	@crate_file="target/package/`sed -n 's|^name = "\(.*\)"|\1|p' Cargo.toml | head -n 1`-`sed -n 's|^version = "\(.*\)"|\1|p' Cargo.toml | head -n 1`.crate"; \
		test -f "$$crate_file" || { echo "$(RED)[ERROR]$(NC) cargo package produced no $$crate_file"; exit 1; }; \
		crate_bytes=`wc -c < "$$crate_file" | tr -d ' '`; \
		test "$$crate_bytes" -le ${CRATE_MAX_BYTES} || { echo "$(RED)[ERROR]$(NC) $$crate_file is $$crate_bytes bytes, over the crates.io limit of ${CRATE_MAX_BYTES} - trim Cargo.toml's exclude list"; exit 1; }; \
		echo "$(GREEN)[SUCCESS]$(NC) $$crate_file is $$crate_bytes bytes (crates.io limit: ${CRATE_MAX_BYTES})"
# --locked, as in publish_crate: a Cargo.lock that would need updating fails here, before the push.
	cargo publish --dry-run --allow-dirty --locked

publish_crate: check_cargo_token check_crate_metadata ## Publish the committed crate to crates.io, built against the committed Cargo.lock (needs CARGO_REGISTRY_TOKEN)
# cargo reads CARGO_REGISTRY_TOKEN from the environment (this Makefile exports it), so the token
# never appears on a command line or in the build log. No --allow-dirty: cargo refuses a tree with
# uncommitted changes, so the upload is exactly the tagged commit. --locked: it is built against
# the Cargo.lock that commit carries, and a lockfile that would need updating is an error.
#
# A version crates.io already has is skipped, not uploaded again. `release` proved before its first
# push that the version was not there, so finding it here means an earlier release_publish uploaded
# it and then failed at the GitHub release - which is what makes ondewo_release_publish rerunnable.
	@code=`$(CRATES_IO_VERSION_HTTP_CODE)`; \
	case "$$code" in \
		200) echo "$(YELLOW)[WARN]$(NC) crates.io already has ondewo-nlu-client ${ONDEWO_NLU_VERSION} - nothing to upload";; \
		404) echo "$(BLUE)[INFO]$(NC) cargo publish --locked - ondewo-nlu-client ${ONDEWO_NLU_VERSION} to crates.io ..."; \
			cargo publish --locked || exit 1; \
			echo "$(GREEN)[SUCCESS]$(NC) Published ondewo-nlu-client ${ONDEWO_NLU_VERSION} to crates.io";; \
		*) echo "$(RED)[ERROR]$(NC) could not ask crates.io whether it has ondewo-nlu-client ${ONDEWO_NLU_VERSION} (HTTP $$code from ${CRATES_IO_VERSION_URL}) - nothing was uploaded"; exit 1;; \
	esac

package_crate: ## Package the crate locally (the same artifact `make publish_crate` uploads)
	cargo package

########################################################
#		DEVOPS-ACCOUNTS

ondewo_release: update_cargo_version spc clone_devops_accounts run_release_with_devops ## Release with credentials from devops-accounts repo
	@rm -rf ${DEVOPS_ACCOUNT_GIT}

ondewo_release_publish: clone_devops_accounts ## Resume a release that stopped after its tag push: release_publish with the devops-accounts credentials
# The same code path as the end of `release`, run in the checkout that release left behind (on
# release/<version>, at the tag). Safe to rerun: publish_crate skips a version crates.io already has.
# One line, so that the credentials clone is removed on a failure too - this target is run by hand,
# without the trap that ondewo-nlu-api's release_client puts around ondewo_release.
	@make run_release_with_devops RELEASE_TARGET=release_publish; rc=$$?; rm -rf ${DEVOPS_ACCOUNT_GIT}; exit $$rc

clone_devops_accounts: ## Clones devops-accounts repo
	if [ -d $(DEVOPS_ACCOUNT_GIT) ]; then rm -Rf $(DEVOPS_ACCOUNT_GIT); fi
	git clone git@bitbucket.org:ondewo/${DEVOPS_ACCOUNT_GIT}.git

run_release_with_devops: ## Gets Credentials from devops-repo and run release command with them
# EXACTLY the two credentials this client uses, each read with an ANCHORED grep: the devops files
# open with '#' comment lines that name variables, and a comment line reaching the command line
# below would comment out every credential after it. @-prefixed, so make never echoes the expanded
# line with the tokens in it.
	$(eval info:= $(shell grep -hE '^GITHUB_GH_TOKEN=' ${DEVOPS_ACCOUNT_DIR}/account_github.env; grep -hE '^CARGO_REGISTRY_TOKEN=' ${DEVOPS_ACCOUNT_DIR}/account_cargo.env))
	@make ${RELEASE_TARGET} $(info)

spc: ## Checks that the Release Branch and Tag do not exist yet and that Cargo.toml carries ONDEWO_NLU_VERSION
	$(eval filtered_branches:= $(shell git branch --all | grep "release/${ONDEWO_NLU_VERSION}"))
	$(eval filtered_tags:= $(shell git tag --list | grep "${ONDEWO_NLU_VERSION}"))
	$(eval cargo_version:= $(shell sed -n 's|^version = "\(.*\)"|\1|p' Cargo.toml | head -n 1))
	@if test "$(filtered_branches)" != ""; then echo "-- Test 1: Branch exists!!" & exit 1; else echo "-- Test 1: Branch is fine";fi
	@if test "$(filtered_tags)" != ""; then echo "-- Test 2: Tag exists!!" & exit 1; else echo "-- Test 2: Tag is fine";fi
	@if test "$(cargo_version)" != "${ONDEWO_NLU_VERSION}"; then echo "-- Test 3: Cargo.toml not updated!!" & exit 1; else echo "-- Test 3: Cargo.toml is fine";fi
