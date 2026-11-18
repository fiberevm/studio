# Studio sandbox image for AWS Lambda MicroVMs: a dev box (git, node, python, build tools) plus Studio's agent.
FROM public.ecr.aws/lambda/microvms:al2023-minimal
RUN dnf install -y python3 git tar gzip which procps-ng findutils make gcc gcc-c++ nodejs npm && dnf clean all
RUN mkdir -p /home/user
COPY agent.py /opt/studio/agent.py
EXPOSE 8970 9000
CMD ["python3", "/opt/studio/agent.py"]
