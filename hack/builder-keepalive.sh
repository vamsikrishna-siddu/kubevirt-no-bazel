# Keep the builder container alive; hack/dockerized runs commands in it via exec.
# Bazel commands start (and restart) their own server inside the container as needed.
sleep infinity
