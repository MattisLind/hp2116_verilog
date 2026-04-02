// sim_main.cpp
//
// Kodkommentar: Minimal Verilator-slinga med VCD-tracing och tidsstegning.

#include "Vtb_hp12531c.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char **argv) {
    // Kodkommentar: Skapa Verilator-kontext så att vi kan styra simtid.
    VerilatedContext* contextp = new VerilatedContext;

    // Kodkommentar: Skicka vidare kommandoradsargument till Verilator.
    contextp->commandArgs(argc, argv);

    // Kodkommentar: Slå på tracing när egen C++-main används.
    Verilated::traceEverOn(true);

    // Kodkommentar: Skapa toppnivåinstansen av testbänken.
    Vtb_hp12531c* top = new Vtb_hp12531c{contextp};

    // Kodkommentar: Skapa VCD-traceobjekt och koppla det till modellen.
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);

    // Kodkommentar: Öppna VCD-filen i arbetskatalogen.
    tfp->open("tb_hp12531c.vcd");

    // Kodkommentar: Kör simuleringen tills $finish anropas från SystemVerilog.
    while (!contextp->gotFinish()) {
        // Kodkommentar: Utvärdera modellen för aktuell simtid.
        top->eval();

        // Kodkommentar: Dumpa alla trace-signaler till VCD-filen.
        tfp->dump(contextp->time());

        // Kodkommentar: Avancera simtiden ett steg så att delays/event controls fungerar.
        contextp->timeInc(1);
    }

    // Kodkommentar: Säkerställ att sista tillståndet också kommer med.
    top->eval();
    tfp->dump(contextp->time());

    // Kodkommentar: Stäng VCD-filen ordentligt.
    tfp->close();

    delete tfp;
    delete top;
    delete contextp;
    return 0;
}