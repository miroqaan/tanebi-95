# TANEBI 95

> A spark becomes a world.

브라우저가 아닌 x86-64 UEFI 환경에서 직접 부팅되는 [TANEBI](https://github.com/miroqaan/tanebi-lang) 기반 운영체제 프로젝트다. Rust `no_std` 커널은 GOP에서 프레임버퍼 주소를 받은 뒤 `ExitBootServices`로 펌웨어 부팅 서비스를 종료하고 1990년대풍 데스크톱을 직접 그린다.

![TANEBI 95 native desktop](docs/tanebi95-native.png)

## 특징

- 64MiB FAT16 x86-64 UEFI 부팅 이미지
- `ExitBootServices` 이후 bare-metal 실행
- GOP 프레임버퍼 직접 렌더링
- PS/2 I/O 포트 기반 키보드·마우스 입력과 소프트웨어 커서
- TANEBI 스크립트로 생성하는 결정론적 부팅 매니페스트
- TANEBI Studio, 시작 메뉴, 전원 화면
- DOOM ARENA: 재부팅을 통해 UEFI DOOM과 Freedoom Phase 2 실행

## 빌드

```powershell
.\scripts\build.ps1
```

산출물:

- `build/esp/EFI/BOOT/BOOTX64.EFI`
- `build/tanebi95.img` — 64MiB FAT16 UEFI 부팅 이미지

## 실행

QEMU와 x86-64 EDK2 펌웨어가 필요하다.

```powershell
.\scripts\run.ps1
```

키보드:

- `S`: 시작 메뉴
- `T`: TANEBI Studio 창 열기/닫기
- `Esc`: 전원 화면
- `D`: DOOM ARENA로 재부팅

DOOM에서는 방향키로 이동·회전, `Space`로 사격, `E`로 문을 연다.
게임 오디오는 현재 비활성화돼 있다.
DOOM은 기본 1280×800 모드에서 원본 320×200을 4배 정수 확대해 전체 화면으로 표시한다.
해당 모드가 없으면 현재 화면에 맞는 최대 정수 배율을 사용한다. 게임 시야는 상태 표시줄을 남긴 최대 크기가 기본이다.

마우스:

- 바탕화면의 `TANEBI STUDIO` 아이콘 클릭
- `START` 버튼과 시작 메뉴 항목 클릭
- Studio 창의 닫기 버튼 클릭

현재 입력은 PS/2 상대 좌표 방식이다. QEMU 화면을 클릭해 마우스를 캡처한 뒤 게스트 내부 포인터를 기준으로 조작한다.
빠른 이동도 패킷 헤더의 9비트 부호를 사용해 처리하며, 오버플로가 표시된 축은 무시한다.
최소화한 창에서 백그라운드 실행하려면 `scripts/run.ps1 -SkipBuild -Background -MonitorPort 45454`를 사용한다. `HeadlessTest`만 화면 없이 실행한다.

## 현재 경계

DOOM은 커널 내부 프로세스가 아니다. 데스크톱이 CMOS 부팅 선택 값을 기록하고 재부팅하면 부트 매니저가 EDK II Shell과 UEFI DOOM을 실행한다. 데스크톱과 게임 모두 QEMU 가상 머신 안에서 실행된다. 게임을 종료한 뒤 QEMU를 재시작하면 데스크톱으로 돌아온다.

네이티브 버전의 Studio는 빌드 시 생성된 TANEBI 결과를 표시한다. 웹판의 YouTube 플레이어, 네트워크, 동영상 디코더, 오디오 드라이버는 아직 네이티브 커널에 이식하지 않았다. 소개영상은 이 경계를 명시한다.

이 버전은 실제로 UEFI에서 부팅한 뒤 펌웨어 부팅 서비스를 종료하는 bare-metal Stage 1이다. 이후 화면은 프레임버퍼 메모리에 직접 쓰고 키보드는 PS/2 I/O 포트에서 scan code를 읽는다.

빌드 시 공개 모듈 `github.com/miroqaan/tanebi-lang/cmd/tanebi@v0.1.0`이 `system.tanebi`를 실행하고 결정론적 결과를 커널에 포함한다. TANEBI 자체를 Ring 3 프로세스로 실행하는 단계는 페이지 테이블·syscall·프로세스 로더 이후 로드맵이다.

## 검증

```powershell
.\scripts\test.ps1
```

테스트는 PS/2 이동 값 262,144개 조합과 오버플로 처리, TANEBI 매니페스트, UEFI PE, FAT16 구조를 검사하고 QEMU에서 `ExitBootServices` 이후 bare-metal marker까지 확인한다.

## 프로젝트 구조

```text
kernel/          Rust no_std UEFI kernel and framebuffer desktop
scripts/         build, QEMU run, and native boot test
tools/mkfat16/   deterministic FAT16 image builder
system.tanebi    TANEBI boot program
docs/            verified native screenshot
```

Microsoft Windows 95, 호환 레이어 또는 에뮬레이터가 아니며 Microsoft의 코드·상표 이미지·에셋을 포함하지 않는 독자적인 데스크톱이다.
