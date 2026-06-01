// SPDX-License-Identifier: GPL-3.0
// Mach exception server that captures EXC_BAD_INSTRUCTION / EXC_BAD_ACCESS / EXC_BREAKPOINT
// faults that POSIX signal handlers don't see (e.g., when the kernel raises Mach exceptions
// but the in-process signal handler is bypassed by codesigning/TXM/launchd).
//
// On capture, dumps thread state (PC, LR, SP, FP, exc_code) to stderr and re-raises by
// forwarding the message to the previously-registered exception port (typically Apple's
// ReportCrash) so the system still gets a chance to generate its own crash log.

#include <mach/mach.h>
#include <mach/exception_types.h>
#include <mach/thread_act.h>
#include <mach/thread_status.h>
#include <pthread.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>

#include "common/HostSys.h"

namespace {
// Mirror of IsStoreInstruction in IOSMisc.cpp — duplicated locally to avoid
// exposing it. ARM64 load/store family detection from the faulting opcode.
inline bool MachIsStoreInstruction(const void* ptr) {
	uint32_t bits;
	std::memcpy(&bits, ptr, sizeof(bits));
	if ((bits & 0x0a000000) != 0x08000000)
		return false;
	if ((bits & 0x3a000000) == 0x28000000)
		return (bits & (1 << 22)) == 0;
	switch (bits & 0xC4C00000) {
		case 0x00000000: case 0x40000000: case 0x80000000: case 0xC0000000:
		case 0x04000000: case 0x44000000: case 0x84000000: case 0xC4000000:
		case 0x04800000:
			return true;
		default:
			return false;
	}
}
} // namespace

extern "C" {

#define MAX_EXCEPTION_PORTS 16
struct PrevPorts {
	exception_mask_t masks[MAX_EXCEPTION_PORTS];
	mach_port_t ports[MAX_EXCEPTION_PORTS];
	exception_behavior_t behaviors[MAX_EXCEPTION_PORTS];
	thread_state_flavor_t flavors[MAX_EXCEPTION_PORTS];
	mach_msg_type_number_t count;
};

static PrevPorts s_prev_ports;
static mach_port_t s_exc_port = MACH_PORT_NULL;
static exception_mask_t MakeMask(bool include_breakpoint) {
	exception_mask_t mask =
	EXC_MASK_BAD_INSTRUCTION |
	EXC_MASK_BAD_ACCESS |
	EXC_MASK_ARITHMETIC |
	EXC_MASK_GUARD;
	if (include_breakpoint)
		mask |= EXC_MASK_BREAKPOINT;
	return mask;
}

// MIG-style message format used by the kernel for mach exceptions with
// EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES behavior.
typedef struct {
	mach_msg_header_t Head;
	NDR_record_t NDR;
	exception_type_t exception;
	mach_msg_type_number_t codeCnt;
	int64_t code[2];
} MachExcMsg;

typedef struct {
	mach_msg_header_t Head;
	NDR_record_t NDR;
	kern_return_t RetCode;
} MachExcReply;

static const char* ExcName(exception_type_t e) {
	switch (e) {
		case EXC_BAD_ACCESS: return "EXC_BAD_ACCESS";
		case EXC_BAD_INSTRUCTION: return "EXC_BAD_INSTRUCTION";
		case EXC_ARITHMETIC: return "EXC_ARITHMETIC";
		case EXC_BREAKPOINT: return "EXC_BREAKPOINT";
		case EXC_GUARD: return "EXC_GUARD";
		case EXC_CRASH: return "EXC_CRASH";
		default: return "EXC_?";
	}
}

static bool CaptureBreakpointsAfterJITDetach() {
	const char* value = std::getenv("AM_PS2_CAPTURE_BREAKPOINT");
	return value && (std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0);
}

static void DumpThread(thread_t th, exception_type_t exc, int64_t code0, int64_t code1) {
	arm_thread_state64_t st = {};
	mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
	kern_return_t kr = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt);
	char buf[512];
	uintptr_t pc_raw = (kr == KERN_SUCCESS) ? (uintptr_t)__darwin_arm_thread_state64_get_pc(st) : 0;
	uintptr_t lr_raw = (kr == KERN_SUCCESS) ? (uintptr_t)__darwin_arm_thread_state64_get_lr(st) : 0;
	uintptr_t sp = (kr == KERN_SUCCESS) ? (uintptr_t)__darwin_arm_thread_state64_get_sp(st) : 0;
	uintptr_t fp = (kr == KERN_SUCCESS) ? (uintptr_t)__darwin_arm_thread_state64_get_fp(st) : 0;
	// Strip PAC bits (top 24 bits) from PC/LR to recover the actual VA.
	const uintptr_t kVAMask = 0x0000007FFFFFFFFFull;
	uintptr_t pc = pc_raw & kVAMask;
	uintptr_t lr = lr_raw & kVAMask;
	uint32_t b0 = 0, b1 = 0, b2 = 0, b3 = 0;
	if (pc >= 0x100000000ull && pc < 0xf00000000000ull) {
		const uint32_t* p = (const uint32_t*)pc;
		b0 = p[0]; b1 = p[1]; b2 = p[2]; b3 = p[3];
	}
	int n = snprintf(buf, sizeof(buf),
		"AMPS2 MACHEXC %s code=0x%llx,0x%llx pc=%lx (raw %lx) lr=%lx (raw %lx) sp=%lx fp=%lx bytes=%08x %08x %08x %08x\n",
		ExcName(exc), (long long)code0, (long long)code1,
		(unsigned long)pc, (unsigned long)pc_raw,
		(unsigned long)lr, (unsigned long)lr_raw,
		(unsigned long)sp, (unsigned long)fp,
		b0, b1, b2, b3);
	if (n > 0) {
		(void)write(STDERR_FILENO, buf, (size_t)n);
	}
	if (kr == KERN_SUCCESS) {
		for (int i = 0; i < 31; i += 4) {
			int m = snprintf(buf, sizeof(buf),
				"AMPS2 MACHEXC x%d=%llx x%d=%llx x%d=%llx x%d=%llx\n",
				i, (unsigned long long)st.__x[i],
				i+1, (i+1<31)?(unsigned long long)st.__x[i+1]:0ull,
				i+2, (i+2<31)?(unsigned long long)st.__x[i+2]:0ull,
				i+3, (i+3<31)?(unsigned long long)st.__x[i+3]:0ull);
			if (m > 0) (void)write(STDERR_FILENO, buf, (size_t)m);
		}
		n = 0; // suppress duplicate write below
	}
	if (n > 0) {
		(void)write(STDERR_FILENO, buf, (size_t)n);
		(void)fsync(STDERR_FILENO);
	}
}

static void* ExceptionThread(void*) {
	// Exception messages from kernel can include port descriptors (thread/task) and
	// trailers; use a generous fixed buffer rather than dynamic resize.
	// MIG-generated mach exception messages are pragma pack(4); without matching it,
	// int64_t code[] would 8-align and read 4 bytes past where the kernel wrote.
#pragma pack(push, 4)
	struct Buf {
		mach_msg_header_t Head;
		mach_msg_body_t msgh_body;
		mach_msg_port_descriptor_t thread;
		mach_msg_port_descriptor_t task;
		NDR_record_t NDR;
		exception_type_t exception;
		mach_msg_type_number_t codeCnt;
		int64_t code[2];
		// padding for trailer
		char trailer[256];
	};
#pragma pack(pop)
	for (;;) {
		Buf req;
		MachExcReply rep;
		mach_msg_return_t mr = mach_msg(&req.Head, MACH_RCV_MSG,
			0, sizeof(req), s_exc_port,
			MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		if (mr != MACH_MSG_SUCCESS) {
			char b[80];
			int n = snprintf(b, sizeof(b), "AMPS2 MACHEXC mach_msg recv err=0x%x\n", mr);
			(void)write(STDERR_FILENO, b, (size_t)n);
			// Hard stop on receive error to avoid log spam.
			sleep(1);
			continue;
		}

		// thread port is msgh_body descriptors[0]
		thread_t th = req.thread.name;

		// Forward EXC_BAD_ACCESS to PCSX2's fastmem fault recovery before any dump/kill.
		// On Darwin, Mach exceptions take precedence over BSD signals — so PCSX2's
		// signal-based SegFault handler never runs. Without this forwarding, every
		// fastmem SEGV terminates the process instead of triggering backpatch.
		kern_return_t recover = KERN_FAILURE;
		bool recovered = false;
		if (req.exception == EXC_BAD_ACCESS && req.codeCnt >= 2) {
			arm_thread_state64_t st = {};
			mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
			if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
				const uintptr_t kVAMask = 0x0000007FFFFFFFFFull;
				uintptr_t pc = ((uintptr_t)__darwin_arm_thread_state64_get_pc(st)) & kVAMask;
				uintptr_t fault_addr = (uintptr_t)req.code[1];
				bool is_write = false;
				if (pc >= 0x100000000ull && pc < 0xf00000000000ull)
					is_write = MachIsStoreInstruction((const void*)pc);
				PageFaultHandler::HandlerResult r =
					PageFaultHandler::HandlePageFault((void*)pc, (void*)fault_addr, is_write);
				if (r == PageFaultHandler::HandlerResult::ContinueExecution) {
					recover = KERN_SUCCESS;
					recovered = true;
				}
			}
		}

		if (!recovered) {
			DumpThread(th, req.exception,
				req.codeCnt >= 1 ? req.code[0] : 0,
				req.codeCnt >= 2 ? req.code[1] : 0);
		}

		rep.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req.Head.msgh_bits), 0);
		rep.Head.msgh_size = sizeof(rep);
		rep.Head.msgh_remote_port = req.Head.msgh_remote_port;
		rep.Head.msgh_local_port = MACH_PORT_NULL;
		rep.Head.msgh_id = req.Head.msgh_id + 100;
		rep.NDR = NDR_record;
		rep.RetCode = recovered ? recover : KERN_FAILURE;
		(void)mach_msg(&rep.Head, MACH_SEND_MSG, sizeof(rep), 0,
			MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	}
	return nullptr;
}

static void AMIOSInstallMachExceptionHandlerInternal(bool include_breakpoint, const char* reason) {
	kern_return_t kr = KERN_SUCCESS;
	if (s_exc_port == MACH_PORT_NULL) {
		kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s_exc_port);
		if (kr != KERN_SUCCESS) {
			fprintf(stderr, "AMPS2 MACHEXC port_allocate failed kr=%d\n", kr);
			return;
		}
		kr = mach_port_insert_right(mach_task_self(), s_exc_port, s_exc_port, MACH_MSG_TYPE_MAKE_SEND);
		if (kr != KERN_SUCCESS) {
			fprintf(stderr, "AMPS2 MACHEXC insert_right failed kr=%d\n", kr);
			return;
		}
	}

	const exception_mask_t mask = MakeMask(include_breakpoint);

	// Save previous ports so we know who would have handled.
	s_prev_ports.count = MAX_EXCEPTION_PORTS;
	(void)task_get_exception_ports(mach_task_self(), mask,
		s_prev_ports.masks, &s_prev_ports.count,
		s_prev_ports.ports, s_prev_ports.behaviors, s_prev_ports.flavors);

	kr = task_set_exception_ports(mach_task_self(), mask, s_exc_port,
		(exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
		ARM_THREAD_STATE64);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "AMPS2 MACHEXC set_exception_ports failed kr=%d\n", kr);
		return;
	}

	static bool s_thread_started = false;
	if (!s_thread_started) {
		pthread_t th;
		pthread_attr_t at;
		pthread_attr_init(&at);
		pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
		pthread_create(&th, &at, ExceptionThread, nullptr);
		pthread_attr_destroy(&at);
		s_thread_started = true;
	}

	fprintf(stderr, "AMPS2 MACHEXC handler armed port=%u breakpoint=%d reason=%s\n",
		s_exc_port, include_breakpoint ? 1 : 0, reason ? reason : "");
	(void)fsync(STDERR_FILENO);
}

void AMIOSInstallMachExceptionHandler() {
	// Keep EXC_BREAKPOINT out while SideStore JIT26 is still active. JIT26 uses
	// BRK #0xf00d for debugger-side syscalls and must receive those stops.
	AMIOSInstallMachExceptionHandlerInternal(false, "initial");
}

void AMIOSReinstallMachExceptionHandlerAfterJITDetach() {
	// JIT26 detach can restore task exception ports. Re-arm after detach and
	// only capture breakpoints for explicit PS2 diagnostics. Breakpoint capture is
	// process-wide and would interfere with other modules' JIT26 BRK protocol.
	AMIOSInstallMachExceptionHandlerInternal(CaptureBreakpointsAfterJITDetach(), "after-jit26-detach");
}

} // extern "C"
