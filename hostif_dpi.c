// hostif_dpi.c
//
// DPI-C support for hostif.sv.
//
// Functions provided:
//   - hostif_putc(int ch): print received UART byte to stdout
//   - hostif_getc_nonblock(): return one stdin byte if available, else -1
//
// This version is POSIX-oriented (Linux/macOS).
// For Windows you would need a different implementation.
//
// Build note:
//   Compile this file as PIC/shared object for your simulator if required.

#include <stdio.h>
#include <unistd.h>
#include <sys/select.h>
#include <termios.h>
#include <stdlib.h>


#ifdef __cplusplus
extern "C" {
#endif

// ------------------------------------------------------------
// Terminal state handling
// ------------------------------------------------------------
static struct termios g_old_termios;
static int g_termios_initialized = 0;

// ------------------------------------------------------------
// Restore terminal settings at exit
// ------------------------------------------------------------
static void hostif_restore_terminal(void) {
    if (g_termios_initialized) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_old_termios);
        g_termios_initialized = 0;
    }
}

// ------------------------------------------------------------
// Put terminal in noncanonical, no-echo mode
// ------------------------------------------------------------
static void hostif_init_terminal(void) {
    if (g_termios_initialized) {
        return;
    }

    struct termios new_termios;

    // Save current terminal settings
    if (tcgetattr(STDIN_FILENO, &g_old_termios) != 0) {
        return;
    }

    new_termios = g_old_termios;

    // Disable canonical mode and echo
    new_termios.c_lflag &= ~(ICANON | ECHO);

    // Make reads return quickly
    new_termios.c_cc[VMIN]  = 0;
    new_termios.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSANOW, &new_termios) == 0) {
        g_termios_initialized = 1;
        atexit(hostif_restore_terminal);
    }
}

// ------------------------------------------------------------
// Called from SystemVerilog when a UART byte is received from DUT
// ------------------------------------------------------------
void hostif_putc(int ch) {
    // Print exactly one byte
    fputc(ch & 0xFF, stdout);

    // Flush immediately so output appears in real time
    fflush(stdout);
}

// ------------------------------------------------------------
// Called from SystemVerilog to poll stdin for one byte
//
// Return values:
//   -1 : no character available
//  0..255 : valid byte
// ------------------------------------------------------------
int hostif_getc_nonblock(void) {
    fd_set readfds;
    struct timeval tv;
    int ret;
    unsigned char ch;

    // Initialize terminal mode once
    hostif_init_terminal();

    FD_ZERO(&readfds);
    FD_SET(STDIN_FILENO, &readfds);

    // Nonblocking select
    tv.tv_sec = 0;
    tv.tv_usec = 0;

    ret = select(STDIN_FILENO + 1, &readfds, NULL, NULL, &tv);
    if (ret <= 0) {
        return -1;
    }

    // Read exactly one byte if available
    if (read(STDIN_FILENO, &ch, 1) == 1) {
        return (int)ch;
    }

    return -1;
}

#ifdef __cplusplus
}
#endif