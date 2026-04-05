// sim_main.cpp
//
// Kodkommentar: Minimal Verilator-slinga där tracing kan stängas av för bättre fart.

#include "Vtb_hp2116.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char** argv) {
    // Kodkommentar: Skapa kontext och skicka vidare argument.
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    // Kodkommentar: Sätt false som standard för maximal prestanda.
    const bool enable_trace = false;

    // Kodkommentar: Slå bara på tracing om det verkligen behövs.
    if (enable_trace) {
        Verilated::traceEverOn(true);
    }

    // Kodkommentar: Skapa toppmodulen.
    Vtb_hp2116* top = new Vtb_hp2116{contextp, "TOP"};

    // Kodkommentar: Skapa traceobjekt endast när tracing används.
    VerilatedVcdC* tfp = nullptr;
    if (enable_trace) {
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("tb_hp2116.vcd");
    }

    // Kodkommentar: Kör tills $finish.
    while (!contextp->gotFinish()) {
        top->eval();

        // Kodkommentar: Dumpa endast om tracing är aktiv.
        if (tfp) {
            tfp->dump(contextp->time());
        }

        // Kodkommentar: Stega tiden.
        contextp->timeInc(1);
    }

    // Kodkommentar: Sista eval/dump.
    top->eval();
    if (tfp) {
        tfp->dump(contextp->time());
        tfp->close();
    }

    delete tfp;
    delete top;
    delete contextp;
    return 0;
}