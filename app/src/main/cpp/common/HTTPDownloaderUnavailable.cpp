// SPDX-FileCopyrightText: 2002-2025 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#include "common/HTTPDownloader.h"
#include "common/Console.h"

class HTTPDownloaderUnavailable final : public HTTPDownloader
{
protected:
	Request* InternalCreateRequest() override
	{
		return new Request();
	}

	void InternalPollRequests() override {}

	bool StartRequest(Request* request) override
	{
		request->status_code = HTTP_STATUS_ERROR;
		request->state = Request::State::Complete;
		Console.Warning("HTTP downloader is not available in this iOS build.");
		return true;
	}

	void CloseRequest(Request* request) override
	{
		delete request;
	}
};

std::unique_ptr<HTTPDownloader> HTTPDownloader::Create(std::string)
{
	return std::make_unique<HTTPDownloaderUnavailable>();
}
