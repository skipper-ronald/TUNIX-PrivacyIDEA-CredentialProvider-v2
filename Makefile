# Makefile - privacyIDEA Credential Provider signeren en distribueren vanaf de Mac.
#
# Bouwen gebeurt op Windows, in deze zelfde boom (E:\claude\privacyidea-credential-provider):
#
#   msbuild PrivacyIDEA-CredentialProvider.sln /p:Configuration=Release /p:Platform=x64 ^
#           /p:PostBuildEventUseInBuild=false
#
# Via ssh kan dat ook; koppel dan eerst E: in die sessie (een sessie met sleutel-login kent
# je wachtwoord niet):
#   net use E: \\192.168.2.200\share-2022 /user:ronald *
#
# Volgorde voor een uitleverbare MSI:
#   1. Windows: DLL's bouwen (bovenstaand commando)
#   2. Mac:     make sign-dlls
#   3. Windows: MSI bouwen zonder de DLL's opnieuw te bouwen (anders zijn ze weer ongesigneerd):
#               msbuild WiXSetup\WiXSetup.wixproj /p:Configuration=Release /p:Platform=x64 ^
#                       /p:BuildProjectReferences=false /p:SolutionDir=%CD%\
#   4. Mac:     make sign-msi

INSTALL_HOST ?= txmaint@192.168.2.209

SIGN_SCRIPT := $(abspath $(CURDIR)/../AuthenticatieService/AsCloudProxy/sign-windows.sh)
SIGN_NAME   := privacyIDEA Credential Provider

CP_DLL     := CredentialProvider/bin/x64/Release/PrivacyIDEACredentialProvider.dll
FILTER_DLL := CredentialProviderFilter/bin/x64/Release/PrivacyIDEACredentialProviderFilter.dll
MSI        := WiXSetup/bin/x64/Release/en-us/privacyIDEACredentialProviderSetup.msi

.PHONY: all help sign-dlls sign-msi install

all: help

help:
	@echo "make sign-dlls - DLL's signeren met het token"
	@echo "make sign-msi  - MSI signeren met het token"
	@echo "make install   - DLL's naar $(INSTALL_HOST) kopieren"

sign-dlls:
	SIGN_NAME="$(SIGN_NAME)" "$(SIGN_SCRIPT)" $(CP_DLL) $(FILTER_DLL)

sign-msi:
	SIGN_NAME="$(SIGN_NAME)" "$(SIGN_SCRIPT)" $(MSI)

install:
	scp -p $(MSI) $(FILTER_DLL) $(CP_DLL) $(INSTALL_HOST):
