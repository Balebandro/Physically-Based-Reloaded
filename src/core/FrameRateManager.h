#pragma once

class FrameRateManager { // Never disposed
public:

	static void		Initialize();

	void			UpdatePerformance();
	double			GetPerformance();
	void			PerformSync();

	LONGLONG		PerformanceFrequency;
	LONGLONG		PerformanceCounterStart;
	double			Time;
	double			LastTime;
	double			ElapsedTime;
	unsigned int	FrameNumber = 0;	// frames since start (UpdatePerformance), for effects that look back a few frames
	double			SmartControlMPF;
	double			LastPerformance;
};