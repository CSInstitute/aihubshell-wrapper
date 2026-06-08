# aihubshell-wrapper
AIHub에서 제공하는 데이터 관리용 CLI인 aihubshell 명령어를 좀 더 사용하기 쉽게 래핑하였습니다.

# Usage

## Install
| Command                    | Description                              |
|----------------------------|------------------------------------------|
| `ahcli install [--reload]` | Clone /opt/aihub + Add to global PATH    |
| `ahcli uninstall`          | Remove /opt/aihub + Delete the PATH line |


## API Key
| Command                 | Description                             |
|-------------------------|-----------------------------------------|
| `ahcli login <KEY>`     | Save API key (~/.config/aihub/key, 600) |
| `ahcli logout`          | Delete saved API key                    |
| `ahcli key`             | Check Cached API Key (Masking)          |


## List
| Command                     | Description            |
|-----------------------------|------------------------|
| `ahcli ls [datasetkey]`     | List of Datasets/Files |
| `ahcli pls [datapckagekey]` | List of Packages/Files |


## Search
| Command                 | Description                               |
|-------------------------|-------------------------------------------|
| `ahcli search [query]`  | Search datasets & packages (table, typed) |


## Downloads
| Command                    | Description                      |
|----------------------------|----------------------------------|
| `ahcli get  <dsk> [fk...]` | Download Dataset (Omitted = All) |
| `ahcli pget <pk>  [fk...]` | Download the package             |


## Environment variables:
| Key name       | Description                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| `AIHUB_PREFIX` | Installation path (Default `/opt/aihub`)                                                               |
| `AIHUB_CONF`   | Key storage file path (Default `~/.config/aihub/key`)                                                  |
| `AIHUB_APIKEY` | Specify key directly (takes precedence over file)<br>  Example) `AIHUB_PREFIX=~/.local/aihub ahcli install` |
