/* openclash-view 命令 [参数...]
 * /bin/sh 是 bash 的发行版（Fedora、RHEL、Arch、openSUSE）上，在本服务的挂载命名空间里把 busybox 挂到 /bin/sh
 * 这个符号链接本身上，再 exec 命令。上游脚本要 busybox ash（bash 当 sh 会展开 nft 规则里的 {tcp,udp}），
 * 上游另有 #!/bin/bash 脚本，bash 本身不能换。systemd 的 BindPaths 和老 mount(2) 都会跟随符号链接挂到 bash 上，
 * 新挂载 API 的 move_mount 不带 MOVE_MOUNT_T_SYMLINKS 时不跟随（内核 ≥ 5.2）。/bin/sh 不是 bash 时什么也不做。
 * 服务的挂载命名空间是 systemd 建的（BindPaths），挂载不会传回宿主。 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef OPEN_TREE_CLONE
#define OPEN_TREE_CLONE 1
#endif
#ifndef MOVE_MOUNT_F_EMPTY_PATH
#define MOVE_MOUNT_F_EMPTY_PATH 0x00000004
#endif

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "用法：openclash-view 命令 [参数...]\n");
		return 2;
	}
	char *sh = realpath("/bin/sh", NULL);
	if (sh && strcmp(strrchr(sh, '/'), "/bash") == 0) {
		/* 保险：和 PID 1 在同一个挂载命名空间（服务没有 PrivateMounts）时不挂，免得换掉宿主的 /bin/sh */
		char self[64] = "", init[64] = "";
		if (readlink("/proc/self/ns/mnt", self, sizeof self - 1) < 0 || readlink("/proc/1/ns/mnt", init, sizeof init - 1) < 0 ||
		    strcmp(self, init) == 0) {
			fprintf(stderr, "openclash-view: 不在服务自己的挂载命名空间里，拒绝挂载 /bin/sh\n");
			return 1;
		}
		int fd = syscall(SYS_open_tree, AT_FDCWD, "/opt/openclash/rt/bin/busybox", OPEN_TREE_CLONE);
		if (fd < 0 || syscall(SYS_move_mount, fd, "", AT_FDCWD, "/bin/sh", MOVE_MOUNT_F_EMPTY_PATH) < 0) {
			perror("openclash-view: 挂载 /bin/sh");
			return 1;
		}
		close(fd);
	}
	execvp(argv[1], argv + 1);
	perror(argv[1]);
	return 127;
}
