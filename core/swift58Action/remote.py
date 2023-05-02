import argparse
import os
import subprocess
import paramiko
# from paramiko import SSHException
import zipfile
import sys
import threading
import hashlib
import queue
from fabric import Connection
from scp import SCPClient

REPO_URL = "https://github.com/andreas16700/openwhisk-runtime-swift"
REPO_BRANCH = "test"
# LOCAL_REPO_PATH =
HOST = "clnode004.clemson.cloudlab.us"
USER = "aloizi04"


# HOST = "192.168.0.189"
# USER = "andreasloizides"


def run_cmd(cmd):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=True)
    if result.returncode != 0 and "nothing to commit, working tree clean" not in result.stdout:
        print(f"Error running {cmd}: {result.stderr}")
        exit(1)
    return result.stdout


def make_sure_remote_repo_exists(ssh_client):
    repo_name = os.path.basename(REPO_URL)
    check_repo_cmd = f"[ -d ~/{repo_name} ] && echo exists || echo not_exists"
    repo_exists = exec_remote_cmd(ssh_client, check_repo_cmd)

    if "not_exists" in repo_exists:
        print("Remote repository does not exist. Cloning the repository...")
        clone_cmd = f"git clone {REPO_URL} ~/{repo_name}"
        exec_remote_cmd(ssh_client, clone_cmd)
        print("Remote repository cloned successfully.")
    return repo_name


def get_local_repo_path():
    return run_cmd("git rev-parse --show-toplevel").strip()


def get_rel_path():
    git_root = get_local_repo_path()
    script_path = os.path.abspath(__file__)
    script_dir = os.path.dirname(script_path)
    return os.path.relpath(script_dir, git_root)


def ensure_cont_not_running(ssh_client, name):
    check_container_cmd = f"sudo docker ps -a --filter name=^{name}$ --format='{{{{.Names}}}}'"
    stdin, stdout, stderr = ssh_client.exec_command(check_container_cmd)
    existing_container = stdout.read().decode('utf-8').strip()

    # If the container exists, remove it
    if existing_container == name:
        print(f"Removing existing container with name {name}")
        remove_container_cmd = f"sudo docker rm -f {name}"
        exec_remote_cmd(ssh_client, remove_container_cmd)


def start_container(ssh_client, img_tag, input_file_remote_path, set_shell=False):
    name = "mn2_container"
    # Check if a container with the same name exists
    ensure_cont_not_running(ssh_client, name)
    f = "--entrypoint=\"/bin/sh\"" if set_shell else ""

    # For running on local mac
    # cmd = f"export PATH=$PATH:/usr/local/bin && docker run -d --name {name} {f} mn2 -c \"tail -f /dev/null\""

    cmd = f"sudo docker run -d --name {name} {f} mn2 -c \"tail -f /dev/null\""
    # Create a container from the built image, ignoring the entrypoint and keeping it running
    # create_container_cmd = f"docker create --entrypoint=\"/bin/sh\" {img_tag}"
    c = exec_remote_cmd(ssh_client, cmd)
    print(f"Output of cmd: {c}")
    if not c:
        raise Exception("Failed to create a container")

    # Copy the input file to the container's /swiftAction directory

    # For running on local mac
    # copy_file_cmd = f"export PATH=$PATH:/usr/local/bin && docker cp {input_file_remote_path} {name}:/swiftAction"

    copy_file_cmd = f"sudo docker cp {input_file_remote_path} {name}:/swiftAction"
    exec_remote_cmd(ssh_client, copy_file_cmd)

    # # Start the container
    # start_container_cmd = f"docker start {container_id}"
    # exec_remote_cmd(ssh_client, start_container_cmd)

    return name


def build_remote_img(ssh_client, tag):
    # Calculate REL_PATH
    rel_path = get_rel_path()

    # Update the local repo
    repo_path = get_local_repo_path()
    print(f"Updating local image repo at {repo_path}")
    cmd = f"cd {repo_path} && git checkout {REPO_BRANCH} && git add . && git commit -m 'Update for docker image build: {tag}' && git push origin test"
    run_cmd(cmd)

    repo_name = make_sure_remote_repo_exists(ssh_client)

    # SSH into the remote machine and update the repo
    ssh_commands = [
        f"cd ~/{repo_name}",
        f"git checkout {REPO_BRANCH}",
        "git fetch",
        "git pull",
        f"cd {rel_path}",
        # for local mac
        # f"export PATH=$PATH:/usr/local/bin && docker build -t {tag} ."
        f"sudo docker build -t {tag} ."
    ]
    ssh_cmd = " && ".join(ssh_commands)
    exec_remote_cmd(ssh_client, ssh_cmd)
    print(f"Docker image '{tag}' built successfully on remote machine.")


def zip_directory(path, zip_file):
    with zipfile.ZipFile(zip_file, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(path):
            for f in files:
                if not f.startswith('.') and not f.startswith('_Whisk.swift'):
                    file_path = os.path.join(root, f)
                    archive_path = os.path.relpath(file_path, path)
                    zf.write(file_path, archive_path)


def zip_action_source(source_path, main_name):
    source_zip_name = main_name + "_action.zip"
    print(f"Zippin' source file to {source_zip_name}")
    zip_directory(source_path, source_zip_name)

    # Get the absolute path of the zip file
    abs_zip_path = os.path.abspath(source_zip_name)

    return abs_zip_path


def connect_ssh():
    # Create an instance of the SSH client
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    # Load the private key for authentication
    # key = paramiko.RSAKey.from_private_key_file(priv_key_path)

    # Connect to the remote server using the provided credentials
    print(f"connecting to {HOST} as {USER}")
    ssh.connect(hostname=HOST, username=USER)
    return ssh


def get_file_hash(file_obj, chunk_size=65536):
    hasher = hashlib.sha256()
    for chunk in iter(lambda: file_obj.read(chunk_size), b''):
        hasher.update(chunk)
    return hasher.hexdigest()


def upload_file(ssh_client, file_path, remote_dir):
    # Create the remote directory if it doesn't exist
    mkdir_cmd = f"mkdir -p {remote_dir}"
    exec_remote_cmd(ssh_client, mkdir_cmd)
    # Join the file name with the remote directory
    file_name = os.path.basename(file_path)
    remote_path = os.path.join(remote_dir, file_name)
    # Replace ~ with . since the home directory is already the working directory of the sftp instance,
    # and apparently it doesn't work with the ~ for some reason :/
    remote_path = remote_path.replace('~', '.')
    print(f"Uploading {file_path} to {remote_path}")

    # Calculate the local file hash
    with open(file_path, 'rb') as local_file:
        local_hash = get_file_hash(local_file)

    # Check if the remote file exists and calculate its hash
    file_name = os.path.basename(file_path)
    remote_path = os.path.join(remote_dir, file_name)
    remote_path = remote_path.replace('~', '.')  # Replace ~ with .

    check_file_cmd = f"if [ -f {remote_path} ]; then sha256sum {remote_path}; else echo 'not_exists'; fi"
    stdin, stdout, stderr = ssh_client.exec_command(check_file_cmd)
    output = stdout.read().decode('utf-8')

    # If the remote file exists and the hashes are the same, exit early
    if 'not_exists' not in output and local_hash in output:
        print("File already exists and is identical. Skipping upload.")
        return remote_path
    # Use SFTP to upload the file
    sftp = ssh_client.open_sftp()

    sftp.put(file_path, remote_path)
    print("Success!")
    sftp.close()
    return remote_path


def exec_remote_cmd(ssh_client, cmd, cwd=None):
    # Execute the command
    if cwd is not None:
        cmd = f"cd {cwd} && {cmd}"
    print(f"Executing \"{cmd}\"...")

    stdin, stdout, stderr = ssh_client.exec_command(command=cmd)

    def line_buffered(f):
        line_buf = ""
        while not f.channel.exit_status_ready():
            line_buf += f.read(1).decode("utf-8")
            if line_buf.endswith('\n'):
                yield line_buf
                line_buf = ''

    def stream_output(f, q, is_stderr=False):
        o = ""
        for line in line_buffered(f):
            o += (line.strip() + "\n")
            if is_stderr:
                print(line.strip(), file=sys.stderr)
                # stderr_read += line.strip()+"\n"
            else:
                print(line.strip())
        q.put(o)

    out_q = queue.Queue()
    err_q = queue.Queue()
    # Stream the output of the command using threads
    stdout_thread = threading.Thread(target=stream_output, args=(stdout, out_q))
    stderr_thread = threading.Thread(target=stream_output, args=(stderr, err_q, True))

    stdout_thread.start()
    stderr_thread.start()

    stdout_thread.join()
    stderr_thread.join()
    err = err_q.get()
    out = out_q.get()
    if err:
        print(f"Error: {err}")
    return out


# Example usage
FUN_NAME = "GetSourceData"
LOCAL_PATH = "/Users/andrew_yos/Library/Mobile Documents/com~apple~CloudDocs/ot-serverless/OT_Serverless_Funcs" \
             "/GetSourceData"
R_PATH = f"~/{FUN_NAME}"
PRIVATE_KEY = "~/.ssh/id_rsa"


# upload_file(FNAME, R_PATH, USER, HOST, PRIVATE_KEY)
def attach_to_container(container_id):
    conn = Connection(host=HOST, user='aloizi04')
    # Start an interactive shell within the container
    exec_command = f"sudo docker exec -it {container_id} /bin/sh"

    # Run the command using fabric.Connection.run, setting pty=True for an interactive session
    result = conn.run(exec_command, pty=True)
    return result


def print_instructions(cont_id, zip_path):
    zip_name = os.path.basename(zip_path)
    run_cont_cmd = f"ssh {USER}@{HOST} && sudo docker exec -it {cont_id} /bin/sh"
    print(f"Attatch to the container: \n{run_cont_cmd}")
    compile_cmd = f"/bin/proxy -compile {FUN_NAME} -debug <{zip_name} >o"
    print(f"Try compiling the action: \n {compile_cmd}")


# def download_action_package(ssh_client):
#
def compile_package(ssh_client, zip_path, img_tag):
    name = "o.zip"
    # for local mac
    # cmd = f"export PATH=$PATH:/usr/local/bin && docker run -d -i {img_tag} -compile {FUN_NAME} -debug <{zip_path} >{name}"
    cont_name = "compiled"
    cmd = f"sudo docker run --name {cont_name} -i {img_tag} -compile {FUN_NAME} -debug <{zip_path} >{name}"
    exec_remote_cmd(ssh_client, cmd)
    return cont_name



def download_action_pack_source(ssh_client, cont_name):
    # for local mac
    # cmd = f"export PATH=$PATH:/usr/local/bin && docker cp {cont_name}:/swiftAction/action/1/src ."

    cmd = f"sudo docker cp {cont_name}:/swiftAction/action/1/src ."
    exec_remote_cmd(ssh_client, cmd)

    scp = SCPClient(ssh_client.get_transport())
    remote_out = f"~/src"
    local_output_path = f"."
    print(f'downloading recursively from {remote_out} to {local_output_path}')
    # Download the remote output folder to the local path using SCPClient
    scp.get(remote_out, local_output_path, recursive=True)


def main():
    parser = argparse.ArgumentParser(description="Build a docker image for a custom OpenWhisk Swift runtime.")
    parser.add_argument("image_tag", help="The name (tag) of the docker image")
    args = parser.parse_args()
    tag = args.image_tag

    ssh_client = connect_ssh()
    zipped = zip_action_source(LOCAL_PATH, FUN_NAME)
    remote_zip_path = upload_file(ssh_client=ssh_client, file_path=zipped, remote_dir=R_PATH)
    build_remote_img(ssh_client, tag)

    container_name = start_container(ssh_client=ssh_client, img_tag=tag, input_file_remote_path=remote_zip_path, set_shell=True)
    # Attach to the running container and open a shell
    # attach_to_container(container_id)
    print_instructions(container_name, zipped)
    name = compile_package(ssh_client, remote_zip_path, tag)
    download_action_pack_source(ssh_client, name)
    ssh_client.close()


if __name__ == "__main__":
    main()
