# コンテナ技術


[コンテナユーザなら誰もが使っているランタイム「runc」を俯瞰する[Container Runtime Meetup #1発表レポート]](https://link.medium.com/4V8dauEqycb)

* namespaces
* cgroups
* pivot_rot
* AppArmor, SELinux, seccomp



## Build Your Own Container Using Less than 100 Lines of Go

https://www.infoq.com/articles/build-a-container-golang/

3つの要素 namespace, cgroup, layered filesystem.

namespace https://man7.org/linux/man-pages/man7/namespaces.7.html

* PID : プロセスID
* MNT : マウント情報. pivot_root
* NET : ネットワーク
* UTS : ホスト名、ドメイン名
* IPC : inter-process communication
* USER : uid

cgroup

あまり語られていない。プロセスやタスクIDを管理し、制限を課すもの。

layered filesystem

そのまま。Btrfsはコピーによって実現し、Aufsは"union mounts"、共有？

### 実装

* namespace と filesystem の取り回し
* /proc/self/exe : 実行されている実行ファイルへのリンク
* cgroupはスキップ
* ファイルシステムの効率的な操作はスキップ
* cloneflags のあたりは、manを参照したほうがよい
* syscall.PivotRootでエラーになる


## cgroup

https://gihyo.jp/admin/serial/01/linux_containers/0003

TODO

## いろいろ

https://eh-career.com/engineerhub/entry/2019/02/05/103000

https://github.com/cssivision/container

TODO

