#pragma once

inline void BounceLightReprojection(const D3DXMATRIX& viewNow, const D3DXMATRIX& invViewNow,
	const D3DXMATRIX& viewLast, const D3DXMATRIX& invViewLast, const D3DXMATRIX& projLast, D3DXMATRIX* result) {
	double rotation[3][3];
	for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
		double sum = 0.0;
		for (int k = 0; k < 3; k++) sum += (double)viewNow.m[k][i] * (double)viewLast.m[k][j];
		rotation[i][j] = sum;
	}
	const double move[3] = { (double)invViewNow._41 - invViewLast._41, (double)invViewNow._42 - invViewLast._42,
		(double)invViewNow._43 - invViewLast._43 };
	double translation[3];
	for (int j = 0; j < 3; j++) translation[j] = move[0] * viewLast.m[0][j] + move[1] * viewLast.m[1][j] + move[2] * viewLast.m[2][j];
	D3DXMATRIX toLastView;
	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) toLastView.m[i][j] = (float)rotation[i][j];
		toLastView.m[i][3] = 0.0f;
		toLastView.m[3][i] = (float)translation[i];
	}
	toLastView.m[3][3] = 1.0f;
	D3DXMatrixMultiply(result, &toLastView, &projLast);
}
