# Prompt: Generate a Professional Project Documentation (Word Document)

You are an expert Technical Writer, Computer Architecture Professor, AI Hardware Researcher, and IEEE paper author.

## Project Title
**Design and Implementation of a 4×4 Weight-Stationary Systolic Array using Multiply-Accumulate (MAC) Units**

## Goal
Generate a complete, textbook-quality Microsoft Word (.docx) project report suitable for:
- Final Year Engineering Project Submission
- IEEE-style Technical Report
- University Viva
- Project Documentation

The document should read like a textbook, not like AI-generated notes.

## Writing Style
- Professional textbook style.
- Smooth narrative flow.
- Every chapter should naturally lead to the next.
- Include explanations, equations, examples, tables, diagrams (placeholders), and chapter summaries.
- Use Heading 1, Heading 2, Heading 3 styles.

## Story Flow
Humans needed calculations
→ Multiplication
→ Large-scale multiplication
→ Matrices
→ Matrix multiplication
→ AI and neural networks
→ Why CPUs are insufficient
→ Need for parallel hardware
→ Systolic Arrays
→ Processing Elements
→ Weight-Stationary Architecture
→ 4×4 Architecture
→ Google TPU
→ Conclusion

## Chapters

### Chapter 1: Introduction
- Introduction to Multiplication
- Introduction to Matrix Multiplication
- Why Matrix Multiplication is Important
- Include C=A×B and Cij=Σ(Aik×Bkj)
- Complete 2×2 worked example
- AI, ML, DSP, Graphics, Robotics applications

### Chapter 2: Systolic Array Fundamentals
- What is a Systolic Array?
- Why is it Called "Systolic"?
- Working Principle
- Data Flow
- MAC equation: Psum = Psum + (A × B)

### Chapter 3: Matrix Multiplication
- Basics
- Normal Matrix Multiplication
- Number of Multiplications and Additions in a 4×4 Matrix
- Drawbacks of Conventional Matrix Multiplication
- Matrix Multiplication Using a Systolic Array
- Comparison: Conventional vs. Systolic Matrix Multiplication

### Chapter 4: Processing Element (PE)
- What is a PE?
- Internal Block Diagram
- Pin Diagram
- MAC Operation
- Working of One PE
- Data Movement Between PEs
Explain every block and signal in detail.

### Chapter 5: Weight-Stationary Architecture
- What is Weight Stationary?
- Why Weights are Stored Inside the PE
- Data Reuse
- Broadcast
- Memory Bandwidth
- Advantages
- Disadvantages
- WS vs OS
- WS vs IS

### Chapter 6: 4×4 Systolic Array Architecture
- Overall Block Diagram
- 16 Processing Elements
- Input/Output Data Flow
- Clock-by-Clock Operation
- Pipeline Filling and Draining
- Number of Clock Cycles
- Timing Diagram
- Latency and Throughput

### Chapter 7: Google TPU Architecture
- What is a TPU?
- TPU Architecture
- Systolic Array Inside the TPU
- Why Google Uses Weight-Stationary
- CPU vs GPU vs TPU

## Figures
Insert placeholders with captions for all major diagrams.

## Tables
Include comparison tables wherever appropriate.

## Quality Requirements
- No factual mistakes.
- Textbook-quality explanations.
- Smooth transitions.
- Suitable for engineering project submission.
- Produce the final output as a polished Microsoft Word (.docx) document.
